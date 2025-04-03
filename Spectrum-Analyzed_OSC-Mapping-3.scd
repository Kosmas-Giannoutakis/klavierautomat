// SuperCollider Frequency Analyzer to Klavierautomat OSC Controller
// Includes three analysis methods: FFTPeak, Pitch detection, and Enhanced FFT
// With combined mode that can blend pitch and FFT analysis using MIDI sliders
// Optimized for tracking glissandi and rapid pitch changes

(
// Main initialization - run this first to set up everything
// First, ensure the server is running
s.waitForBoot {
	"Server booted. Setting up Klavierautomat controller...".postln;

	// === CONFIGURATION SECTION ===
	(


		// OSC setup - adjust to match your Klavierautomat's network settings
		~klavierautomatIP = "192.168.10.1";  // Klavierautomat's IP
		~klavierautomatPort = 7000;          // Klavierautomat's port
		~klavierautomatAddress = "/note";    // OSC address pattern

		// Analysis method selection
		~analysisMethod = \superCombined;     // \fft, \pitch, \enhancedFft, \combined, \polyPitch or \superCombined

		// Timing control parameters
		~updateRate = 0.03;              // Default time between analyses (30 Hz)
		~analysisRoutine = nil;          // Will hold the routine

		// Analysis parameters
		~numFreqsToTrack = 8;            // Number of strongest frequency peaks to track
		~minMIDINote = 21;               // A0 (lowest piano note)
		~maxMIDINote = 108;              // C8 (highest piano note)
		~minFreq = ~minMIDINote.midicps; // Convert MIDI note to Hz
		~maxFreq = ~maxMIDINote.midicps; // Convert MIDI note to Hz
		~fftSize = 2048;                 // FFT size for analysis
		~prevNotes = nil;                // Previously triggered notes for note-off messages
		~analyzerSynth = nil;            // Will hold the current analyzer synth
		~noteBuffer = Dictionary.new;    // For tracking note timings
		~lastDetectedFreq = nil;         // For tracking frequency changes in glissandi

		// Note debouncing to prevent rapid on/off cycling
		~noteDebounce = Dictionary.new;  // For tracking note debounce times
		~debouncePeriod = 0.02;          // Time in seconds to ignore a note after it's turned off
		~minimumNoteDuration = 0.02;     // Minimum time to keep a note on (seconds)

		// Additional parameters for enhanced analysis
		~noiseThreshold = 0.6;           // Threshold for detecting noisy vs tonal signals
		~noiseMapMode = \off;            // Noise mapping mode: \off, \dense, or \sparse

		// Parameters for combined analysis
		~pitchWeight = 0.5;              // Initial weight for pitch analysis (0-1)
		~fftWeight = 0.5;                // Initial weight for FFT analysis (0-1)

		// Language-side variables for slider values
		~pitchAmountValue = 0.3;         // Language-side variable for pitch amount
		~fftAmountValue = 0.7;           // Language-side variable for FFT amount

		// Note stability through history tracking
		~noteHistory = Dictionary.new;   // Track detection history for each note
		~historyLength = 2;              // Number of frames to track
		~requiredCount = 1;              // Required detections to trigger a note

		// Create control buses for the slider values
		~pitchAmountBus = Bus.control(s, 1).set(0.5);  // Default to 0.5
		~fftAmountBus = Bus.control(s, 1).set(0.5);    // Default to 0.5
		~polyPitchAmountBus = Bus.control(s, 1).set(0.5);  // Default to 0.5

		~pedalBus = Bus.control(s, 1).set(0);  // Default pedal position: off
		~lastPedalValue = 0;  // Track the last sent pedal value
		~pedalThreshold = 0.01;  // Minimum change required to send new pedal value

		~pitchNoteMessageInterval = 0.1;   // Default 0.1 seconds for pitch
		~fftNoteMessageInterval = 0.1;     // Default 0.1 seconds for FFT
		~polyNoteMessageInterval = 0.1;    // Default 0.1 seconds for polypitch

		// Tracking timestamps for each mode
		~lastPitchMessageTime = 0;
		~lastFftMessageTime = 0;
		~lastPolyMessageTime = 0;

		// ~monitorBus = Bus(\audio, 12, 1, s);  // Single channel monitor bus

		// Function to update the slider buses from the MIDI sliders
		~updateSliderBuses = {
			// Keep the existing slider value readings
			var pitchAmount = ~sliderValue.value(6);
			var fftAmount = ~sliderValue.value(7);
			var polyPitchAmount = ~sliderValue.value(8);

			// Add pedal control from slider 4
			var pedalValue = ~sliderValue.value(4);

			// Store values in language-side variables
			~pitchAmountValue = pitchAmount;
			~fftAmountValue = fftAmount;
			~polyPitchAmountValue = polyPitchAmount;

			// Update the buses for the synth
			~pitchAmountBus.set(pitchAmount);
			~fftAmountBus.set(fftAmount);
			~polyPitchAmountBus.set(polyPitchAmount);
			~pedalBus.set(pedalValue);

			// Only send OSC messages if pedal value has changed significantly
			if((pedalValue - ~lastPedalValue).abs > ~pedalThreshold) {
				~sendPedalToKlavierautomat.value(pedalValue);
				~lastPedalValue = pedalValue;
			};
		};
	);

	// === BUFFER ALLOCATION ===
	(
		// Allocate buffers for FFT analysis
		~fftBuffer = Buffer.alloc(s, ~fftSize);
		~magBuffer = Buffer.alloc(s, ~fftSize/2);

		// Create OSC client
		~oscClient = NetAddr(~klavierautomatIP, ~klavierautomatPort);
	);

	// === UTILITY FUNCTIONS ===
	(
		// Helper function for safe numeric comparison
		~safeGreaterThan = {|a, b|
			if(a.isNumber && b.isNumber) {
				a > b
			} {
				false
			}
		};

		// Function to convert frequency to closest MIDI note (as Integer)
		~freqToMIDI = {|freq|
			var midi;
			midi = freq.cpsmidi.round(1).asInteger;  // Added asInteger for consistent integer notes
			midi = midi.clip(~minMIDINote, ~maxMIDINote); // Constrain to piano range
			midi;
		};

		// Calculate velocity based on rate of frequency change for glissandi
		~mapGlissandoVelocity = {|freq, prevFreq|
			var velocity = 0.5;  // Default velocity

			// Check notNil first
			if(prevFreq.notNil) {
				// Then check value in separate expression
				if(prevFreq > 0) {
					var change = abs(freq - prevFreq);
					// Higher velocity for faster changes
					velocity = min(0.9, 0.4 + (change * 10));
				};
			};

			velocity;
		};

		// Function to send MIDI note as OSC message to Klavierautomat
		~sendNoteToKlavierautomat = {|note, velocity = 0.7|
			var msg;
			var intNote = note.asInteger;  // Ensure integer notes
			msg = [~klavierautomatAddress, intNote, velocity];
			~oscClient.sendMsg(~klavierautomatAddress, intNote, velocity);
			"OSC: % -> %".format(~oscClient.ip, msg).postln;
		};

		// Function to send note-off message
		~sendNoteOffToKlavierautomat = {|note|
			var msg;
			var intNote = note.asInteger;  // Ensure integer notes
			msg = [~klavierautomatAddress, intNote, 0];
			~oscClient.sendMsg(~klavierautomatAddress, intNote, 0);
			"OSC: % -> %".format(~oscClient.ip, msg).postln;
		};

		// Function to update note history for stability with improved glissando tracking
		// Function to update note history for stability with improved glissando tracking - FIXED VERSION
		~updateNoteHistory = {|notesArray|
			var currentTime, result, intNote, found, checkNote, noteCount;

			// Initialize variables
			currentTime = SystemClock.seconds;
			result = [];

			// Age all entries first
			~noteHistory.keysValuesDo({|note, history|
				if(history.notNil) {
					if(history[\lastTime].notNil) {
						if((currentTime - history[\lastTime]) > 1.0) {
							// Remove old history entries
							~noteHistory.removeAt(note);
						};
					};
				};
			});

			// Update history for current notes
			notesArray.do({|note|
				intNote = note.asInteger;
				found = false;

				// Check if adjacent notes are in history (for glissando tracking)
				[-1, 0, 1].do({|offset|
					checkNote = intNote + offset;
					if(~noteHistory[checkNote].notNil) {
						if(~noteHistory[checkNote][\lastTime].notNil) {
							if((currentTime - ~noteHistory[checkNote][\lastTime]) < 0.2) {
								found = true;
							};
						};
					};
				});

				// Update history for this note
				if(~noteHistory[intNote].isNil) {
					~noteHistory[intNote] = (
						count: 1,
						lastTime: currentTime
					);
				};

				if(~noteHistory[intNote].notNil) {
					// Update count safely
					if(~noteHistory[intNote][\count].notNil) {
						if(~noteHistory[intNote][\count].isNumber) {
							~noteHistory[intNote][\count] = min(~historyLength, ~noteHistory[intNote][\count] + 1);
						};
					};

					if(~noteHistory[intNote][\count].isNil) {
						~noteHistory[intNote][\count] = 1;
					};

					~noteHistory[intNote][\lastTime] = currentTime;
				};

				// Add to result if stable or follows a recent note
				if(~noteHistory[intNote].notNil) {
					noteCount = ~noteHistory[intNote][\count];
					if(noteCount.notNil) {
						if(noteCount.isNumber) {
							if(noteCount >= ~requiredCount || found) {
								result = result.add(intNote);
							};
						};
					};
				};
			});

			result;
		};
	);

	// === SYNTH DEFINITIONS ===
	(
		//-----------------------------------------------------
		// METHOD 1: Basic FFT spectral analysis
		//-----------------------------------------------------
		SynthDef(\fftAnalyzer, {
			var in, mono, chain, trig;

			// All variables must be declared at the beginning
			in = InFeedback.ar(0, 8);
			mono = Mix.ar(in)/8;// Listen to the monitor bus
			chain = FFT(~fftBuffer, mono);
			trig = Impulse.kr(30);     // Faster trigger rate (30 Hz) for better tracking

			// Store magnitudes in the magBuffer using PV_MagBuffer
			chain = PV_MagBuffer(chain, ~magBuffer);

			// Trigger a notification when analysis is ready
			SendReply.kr(trig, '/fft_data_ready');

			// Silent output
			Silent.ar;
		}).add;

		//-----------------------------------------------------
		// METHOD 2: Pitch detection (time domain)
		//-----------------------------------------------------
		SynthDef(\pitchAnalyzer, {
			var in, mono, freq, hasFreq, amp, detectedFreqs, detectedAmps, trigger;
			var i, harmonic, harmAmp;

			// All variables must be declared at the beginning
			in = InFeedback.ar(0, 8);
			mono = Mix.ar(in)/8;// Listen to the monitor bus
			detectedFreqs = Array.fill(~numFreqsToTrack, 0);
			detectedAmps = Array.fill(~numFreqsToTrack, 0);

			// Trigger analysis
			trigger = Impulse.kr(30);     // Faster analysis rate (30 Hz) for better tracking

			// Use Pitch UGen for frequency detection - optimized for glissando
			# freq, hasFreq = Pitch.kr(mono,
				initFreq: 440.0,
				minFreq: ~minFreq,
				maxFreq: ~maxFreq,
				ampThreshold: 0.01,       // Lower threshold for better sensitivity
				median: 3                 // Reduced median for faster tracking of pitch changes
			);

			// Get amplitude at the detected pitch
			amp = Amplitude.kr(mono);

			// Only use frequency if it's valid and has sufficient amplitude
			freq = freq * hasFreq * (amp > 0.01);

			// Fill the first slot with our detected frequency and amplitude
			detectedFreqs[0] = freq;
			detectedAmps[0] = amp;

			// Create harmonics for additional notes
			i = 1;
			while { i < ~numFreqsToTrack } {
				harmonic = freq * (i+1);
				harmAmp = amp / (i+1); // Harmonics typically have less amplitude

				// Only include harmonics in piano range
				harmonic = harmonic * (harmonic <= ~maxFreq);
				harmAmp = harmAmp * (harmonic > 0);

				detectedFreqs[i] = harmonic;
				detectedAmps[i] = harmAmp;

				i = i + 1;
			};

			// Send detected frequencies and amplitudes
			SendReply.kr(
				trigger,
				'/pitch_analysis',
				detectedFreqs ++ detectedAmps
			);
			Silent.ar;
		}).add;

		//-----------------------------------------------------
		// METHOD 3: Enhanced FFT spectral analysis with better tracking
		//-----------------------------------------------------
		SynthDef(\enhancedFftAnalyzer, {
			var in, mono, chain, trig;
			var centroid, flatness, flux;

			// All variables must be declared at the beginning
			in = InFeedback.ar(0, 8);
			mono = Mix.ar(in)/8;// Listen to the monitor bus

			// Use two overlapping FFT chains for better temporal resolution
			chain = FFT(~fftBuffer, mono, wintype: 1);  // Hann window

			// Spectral flux to detect rapid changes
			flux = SpecFlatness.kr(chain);

			// Faster trigger rate for better responsiveness
			trig = Impulse.kr(30);  // 30 Hz for better tracking

			// Store magnitudes in the magBuffer using PV_MagBuffer
			chain = PV_MagBuffer(chain, ~magBuffer);

			// Trigger a notification when analysis is ready
			SendReply.kr(trig, '/enhanced_fft_ready', [flux]);

			// Silent output
			Silent.ar;
		}).add;

		//-----------------------------------------------------
		// METHOD 4: Combined Pitch detection + Enhanced FFT
		//-----------------------------------------------------
		SynthDef(\combinedAnalyzer, {
			var in, mono, chain, trig;
			var freq, hasFreq, amp, flux;
			var pitchFreqs, pitchAmps, i, harmonic, harmAmp;
			var pitchAmount, fftAmount;

			// Read the slider values from control buses
			pitchAmount = In.kr(~pitchAmountBus);
			fftAmount = In.kr(~fftAmountBus);

			// Input and common variables
			in = InFeedback.ar(0, 8);
			mono = Mix.ar(in)/8;// Listen to the monitor bus
			// --- PITCH ANALYSIS SECTION ---
			// Use Pitch UGen for frequency detection - optimized for glissando tracking
			# freq, hasFreq = Pitch.kr(mono,
				initFreq: 440.0,
				minFreq: ~minFreq,
				maxFreq: ~maxFreq,
				ampThreshold: 0.01,      // Lower threshold for better sensitivity
				median: 3                // Reduced median for faster tracking
			);

			// Get amplitude at the detected pitch
			amp = Amplitude.kr(mono);

			// Only use frequency if it's valid and has sufficient amplitude
			freq = freq * hasFreq * (amp > 0.01);

			// Store frequencies and amplitudes for multiple harmonics
			pitchFreqs = Array.fill(~numFreqsToTrack, 0);
			pitchAmps = Array.fill(~numFreqsToTrack, 0);

			// Fill the first slot with our detected frequency and amplitude
			pitchFreqs[0] = freq;
			pitchAmps[0] = amp;

			// Create harmonics for additional notes
			i = 1;
			while { i < ~numFreqsToTrack } {
				harmonic = freq * (i+1);
				harmAmp = amp / (i+1); // Harmonics typically have less amplitude

				// Only include harmonics in piano range
				harmonic = harmonic * (harmonic <= ~maxFreq);
				harmAmp = harmAmp * (harmonic > 0);

				pitchFreqs[i] = harmonic;
				pitchAmps[i] = harmAmp;

				i = i + 1;
			};

			// --- FFT ANALYSIS SECTION ---
			// FFT analysis chain
			chain = FFT(~fftBuffer, mono, wintype: 1);  // Hann window

			// Spectral flux to detect rapid changes
			flux = SpecFlatness.kr(chain);

			// Faster trigger rate for better responsiveness
			trig = Impulse.kr(30);  // 30 Hz for more responsive analysis

			// Store magnitudes in the magBuffer using PV_MagBuffer
			chain = PV_MagBuffer(chain, ~magBuffer);

			// Send all data for combined processing
			SendReply.kr(
				trig,
				'/combined_analysis',
				pitchFreqs ++ pitchAmps ++ [flux]
			);

			// Silent output
			Silent.ar;
		}).add;


		//-----------------------------------------------------
		// METHOD 5: PolyPitch
		//-----------------------------------------------------
		SynthDef(\polyPitchAnalyzer, {
			var in, mono, trigger;
			var polyPitchOut, numVoices, freqs, saliences;
			var detectedFreqs, detectedAmps;

			// Input from the main output bus
			in = InFeedback.ar(0, 8);
			mono = Mix.ar(in)/8;// Listen to the monitor bus
			// The PolyPitch UGen requires 44.1kHz sample rate and 64 sample blocksize
			// Parameters based on the documentation
			polyPitchOut = PolyPitch.kr(
				mono,
				maxvoices: ~numFreqsToTrack,      // Use the same config as other methods
				levelcompressionfactor: -0.02,      // Default from documentation
				mixleftterm: 1.5,                 // Default, good for non-drum signals
				torprec: 1e-05,                   // Default precision
				cancellationweight: 0.7,          // Default weight
				polyphonyestimategamma: 0.4      // Default gamma value
			);

			// Trigger rate for analysis
			trigger = Impulse.kr(30);  // 30 Hz for responsive tracking

			// PolyPitch outputs: [numVoices, freq1, salience1, freq2, salience2, ...]
			numVoices = polyPitchOut[0];  // First output is number of detected voices

			// Initialize arrays to hold extracted data
			detectedFreqs = Array.fill(~numFreqsToTrack, 0);
			detectedAmps = Array.fill(~numFreqsToTrack, 0);

			// Extract frequencies and saliences from the PolyPitch output
			~numFreqsToTrack.do({ |i|
				var idx = i * 2 + 1;  // Skip the numVoices and calculate correct index

				// Only populate within detected voice count
				detectedFreqs[i] = polyPitchOut[idx] * (i < numVoices);

				// Next index is the salience value
				detectedAmps[i] = polyPitchOut[idx + 1] * (i < numVoices);
			});

			// Send detected frequencies and amplitudes at the trigger rate
			SendReply.kr(
				trigger,
				'/polypitch_analysis',
				detectedFreqs ++ detectedAmps ++ [numVoices]
			);
			Silent.ar;
		}).add;

		// Add a combined analyzer that includes PolyPitch with other methods
		SynthDef(\combinedWithPolyPitch, {
			var in, mono, chain, trig;
			var pitchFreq, hasFreq, pitchAmp;
			var polyPitchOut, numVoices;
			var pitchWeight, fftWeight, polyPitchWeight;
			var ampThreshValue = ~knob.(61, 1e-5, 1, \exp);
			var medianValue = ~knob.(62, 1, 10, \lin).round;

			// Read weights from control buses - add a new one for PolyPitch
			pitchWeight = In.kr(~pitchAmountBus);
			fftWeight = In.kr(~fftAmountBus);
			polyPitchWeight = In.kr(~polyPitchAmountBus);  // New control bus

			// Input from main output bus
			in = InFeedback.ar(0, 8);
			mono = Mix.ar(in)/8;// Listen to the monitor bus
			// Basic Pitch detection for monophonic parts and glissandi
			# pitchFreq, hasFreq = Pitch.kr(
				mono,
				initFreq: 200.0,
				minFreq: ~minFreq,
				maxFreq: ~maxFreq,
				ampThreshold: ampThreshValue,
				median: medianValue  // Lower median for faster tracking
			);
			pitchAmp = Amplitude.kr(mono);

			// PolyPitch analysis for polyphonic detection
			polyPitchOut = PolyPitch.kr(
				mono,
				maxvoices: ~numFreqsToTrack,
				levelcompressionfactor: -0.02,
				mixleftterm: 1.5,
				torprec: 1e-05,
				cancellationweight: 0.7,
				polyphonyestimategamma: 0.4
			);

			// FFT analysis chain for spectral content
			chain = FFT(~fftBuffer, mono, wintype: 1);

			// Trigger for analysis
			trig = Impulse.kr(30);  // 30 Hz for more responsive analysis

			// Store magnitudes in the magBuffer
			chain = PV_MagBuffer(chain, ~magBuffer);

			// Send all data for combined processing with weights
			SendReply.kr(
				trig,
				'/super_combined_analysis',
				[pitchFreq, hasFreq, pitchAmp, polyPitchOut[0]] ++
				// Include first 4 frequencies from PolyPitch
				Array.fill(4, {|i| polyPitchOut[i*2+1]}) ++
				// Include first 4 saliences from PolyPitch
				Array.fill(4, {|i| polyPitchOut[i*2+2]})
			);
			Silent.ar;
		}).add;
	);

	// Wait for SynthDefs to be registered with the server
	s.sync;
	"SynthDefs added to server.".postln;

	// === ANALYSIS FUNCTIONS ===
	(
		// Basic buffer analysis function
		~analyzeMagBuffer = {
			var freqs, mags, magArray, peakIndices, i, peaks, binIndex, freq;

			freqs = Array.fill(~numFreqsToTrack, 0);
			mags = Array.fill(~numFreqsToTrack, 0);

			// Get the magnitudes from the buffer
			magArray = ~magBuffer.getn(0, ~fftSize/2, { |vals|
				// Find peaks by comparing each value with its neighbors
				peaks = Array.new;

				// Skip first and last bin to avoid edge cases
				for(1, vals.size-2, { |i|
					// Lower threshold for more sensitivity
					if((vals[i] > vals[i-1]) && (vals[i] > vals[i+1]) && (vals[i] > 0.005)) {
						peaks = peaks.add([i, vals[i]]);  // [index, magnitude]
					};
				});

				// Sort peaks by magnitude (descending)
				peaks = peaks.sort({ |a, b| a[1] > b[1] });

				// Take top N peaks
				peaks = peaks.keep(~numFreqsToTrack);

				// Convert indices to frequencies and collect magnitudes
				peaks.do({ |peak, i|
					binIndex = peak[0];
					freq = binIndex * s.sampleRate / ~fftSize;

					// Only use frequencies in our desired range
					if((freq >= ~minFreq) && (freq <= ~maxFreq)) {
						freqs[i] = freq;
						mags[i] = peak[1];
					};
				});

				// Process these frequencies and magnitudes to MIDI notes
				~processPeaks.value(freqs, mags);
			});
		};

		// Enhanced buffer analysis function with better peak detection and tracking
		~analyzeEnhancedFFT = {|flux, callback|
			var freqs, mags, peakThreshold, magArray, peaks, binIndex, freq;
			var spectralFlux, windowSize, isPeak, peakVal, offset;
			var a, b, c, p, interpolatedBin;
			var validPeaks, selectedPeaks, usedFreqs, isHarmonic, ratio, closestInteger;
			var isNoisy, noiseAmount, noiseBins, lowBinCount, i, j, randomNote;
			var binThreshold, centroidBin, totalEnergy, mappedNote, noteRange, noteOffset;
			var bassMag, midMag, highMag, bassNote, midNote, highNote;
			var fftNotes, fftVelocities;

			spectralFlux = flux ? 0;
			freqs = Array.fill(~numFreqsToTrack, 0);
			mags = Array.fill(~numFreqsToTrack, 0);
			fftNotes = [];
			fftVelocities = [];

			// Lower peak detection threshold for more sensitivity
			peakThreshold = 0.005 * (1 - (spectralFlux * 0.5));

			// Get the magnitudes from the buffer
			magArray = ~magBuffer.getn(0, ~fftSize/2, { |vals|
				windowSize = 5; // Look at nearby bins for better peak detection
				peaks = Array.new;
				validPeaks = Array.new;
				selectedPeaks = Array.new;
				usedFreqs = Set.new;

				// Detect if signal is noisy or tonal
				isNoisy = false;
				noiseAmount = 0;

				// Check for noise by examining the spectral flatness
				// A high spectral flatness indicates noise-like content
				noiseBins = 0;
				lowBinCount = 0;

				// Count how many low frequency bins have energy
				i = 1;
				while { i < (vals.size * 0.1) } {  // Look at lowest 10% of spectrum
					if((vals[i] != nil) && (vals[i] > 0.05)) {
						lowBinCount = lowBinCount + 1;
					};
					i = i + 1;
				};

				// Count bins with energy in full spectrum
				i = 1;
				while { i < vals.size } {
					// Lower threshold for more detection
					if((vals[i] != nil) && (vals[i] > 0.005)) {
						noiseBins = noiseBins + 1;
					};
					i = i + 1;
				};

				// Calculate noise amount as ratio of bins with energy to total bins
				if(vals.size > 0) {
					noiseAmount = noiseBins / vals.size;
					isNoisy = noiseAmount > ~noiseThreshold;
				};

				// Different processing for noisy vs tonal signals
				if(isNoisy && (~noiseMapMode != \off)) {
					if(~noiseMapMode == \dense) {
						// For dense mapping of noise, generate several notes based on spectral centroid
						centroidBin = 0;
						totalEnergy = 0;

						// Calculate spectral centroid (brightness)
						i = 1;
						while { i < vals.size } {
							if(vals[i] != nil) {
								centroidBin = centroidBin + (i * vals[i]);
								totalEnergy = totalEnergy + vals[i];
							};
							i = i + 1;
						};

						if(totalEnergy > 0) {
							centroidBin = centroidBin / totalEnergy;
						};

						// Map centroid to note range
						mappedNote = ((centroidBin / vals.size) * 60 + 30).clip(~minMIDINote, ~maxMIDINote);

						// Generate a cluster of notes around the centroid
						noteRange = 12; // 1 octave range

						i = 0;
						while { i < ~numFreqsToTrack } {
							// Choose semi-random notes in the range
							noteOffset = (i * 7) % noteRange - (noteRange / 2);
							freq = (mappedNote + noteOffset).midicps;
							freqs[i] = freq;

							// Scale magnitude by distance from center
							mags[i] = ((noteRange/2) - noteOffset.abs) / (noteRange/2) *
							noiseAmount.linlin(~noiseThreshold, 1.0, 0.5, 1.0);

							i = i + 1;
						};
					} {
						// Sparse noise mapping - just a few key notes based on energy bands
						bassMag = 0;
						midMag = 0;
						highMag = 0;

						// Calculate energy in different frequency bands
						i = 1;
						while { i < (vals.size * 0.1) } { // Bass (0-10%)
							if(vals[i] != nil) {
								bassMag = bassMag + vals[i];
							};
							i = i + 1;
						};

						while { i < (vals.size * 0.5) } { // Mids (10-50%)
							if(vals[i] != nil) {
								midMag = midMag + vals[i];
							};
							i = i + 1;
						};

						while { i < vals.size } { // Highs (50-100%)
							if(vals[i] != nil) {
								highMag = highMag + vals[i];
							};
							i = i + 1;
						};

						// Normalize by bin count
						bassMag = bassMag / (vals.size * 0.1);
						midMag = midMag / (vals.size * 0.4);
						highMag = highMag / (vals.size * 0.5);

						// Generate one note from each band if it has enough energy
						i = 0;
						if(bassMag > 0.02) {
							bassNote = rrand(~minMIDINote, ~minMIDINote + 12); // Low note
							freqs[i] = bassNote.midicps;
							mags[i] = bassMag.linlin(0.02, 0.2, 0.2, 0.9);
							i = i + 1;
						};

						if(midMag > 0.02 && (i < ~numFreqsToTrack)) {
							midNote = rrand(~minMIDINote + 24, ~minMIDINote + 48); // Mid note
							freqs[i] = midNote.midicps;
							mags[i] = midMag.linlin(0.02, 0.2, 0.2, 0.9);
							i = i + 1;
						};

						if(highMag > 0.02 && (i < ~numFreqsToTrack)) {
							highNote = rrand(~minMIDINote + 60, ~maxMIDINote); // High note
							freqs[i] = highNote.midicps;
							mags[i] = highMag.linlin(0.02, 0.2, 0.2, 0.9);
							i = i + 1;
						};
					};
				} {
					// Normal peak detection for tonal content
					// Improved peak detection - examine each bin in context
					for(windowSize, vals.size-(windowSize+1), { |i|
						isPeak = true;
						peakVal = vals[i];

						// Skip if peakVal is nil
						if(peakVal != nil) {
							// For low freq bins, use lower threshold
							binThreshold = peakThreshold;
							if(i < (vals.size * 0.1)) { // Lower 10% of spectrum
								binThreshold = peakThreshold * 0.3; // Much lower threshold for bass
							};

							// Only consider if above noise threshold
							if(peakVal.notNil && peakVal.isNumber && binThreshold.isNumber && (peakVal > binThreshold)) {
								// Check if it's higher than nearby bins (using window)
								for(1, windowSize, { |offset|
									// Add safety check for nil values
									if((vals[i-offset] != nil) && (vals[i+offset] != nil) &&
										((vals[i-offset] >= peakVal) || (vals[i+offset] >= peakVal))) {
										isPeak = false;
									};
								});

								if(isPeak) {
									// Refine frequency using quadratic interpolation for better accuracy
									if((vals[i-1] != nil) && (vals[i] != nil) && (vals[i+1] != nil)) {
										a = vals[i-1];
										b = vals[i];
										c = vals[i+1];
										p = 0.5 * (a - c) / (a - 2*b + c + 0.00001); // Added small value to prevent division by zero
										interpolatedBin = i + p;

										peaks = peaks.add([interpolatedBin, peakVal]);
									};
								};
							};
						};
					});

					// Sort peaks by magnitude (descending)
					if(peaks.size > 0) {
						peaks = peaks.sort({ |a, b| a[1] > b[1] });

						// Take more peaks initially to have candidates
						peaks = peaks.keep(min(peaks.size, ~numFreqsToTrack * 2));

						// Convert indices to frequencies and filter for music range
						peaks.do({ |peak|
							binIndex = peak[0];
							freq = binIndex * s.sampleRate / ~fftSize;

							// Only use frequencies in our desired range
							if((freq >= ~minFreq) && (freq <= ~maxFreq)) {
								validPeaks = validPeaks.add([freq, peak[1]]);
							};
						});

						// Now select peaks that aren't harmonics of stronger peaks
						validPeaks.do({ |peak|
							isHarmonic = false;

							// Check if this peak is a harmonic of any stronger peak already selected
							usedFreqs.do({ |baseFreq|
								// Check if it's close to an integer multiple of a stronger frequency
								if(baseFreq > 0) {
									ratio = peak[0] / baseFreq;
									closestInteger = ratio.round;

									if((closestInteger > 1) && ((ratio - closestInteger).abs < 0.05)) {
										isHarmonic = true;
									};
								};
							});

							if(isHarmonic.not && (selectedPeaks.size < ~numFreqsToTrack)) {
								selectedPeaks = selectedPeaks.add(peak);
								usedFreqs.add(peak[0]);
							};
						});

						// Fill the output arrays
						selectedPeaks.do({ |peak, i|
							freqs[i] = peak[0];
							mags[i] = peak[1];
						});
					};
				};

				// Convert frequencies to MIDI notes for FFT
				freqs.do({|freq, i|
					var note;
					// Lower threshold for more detection
					if(freq.isNumber && (freq > 0) && mags[i].isNumber && (mags[i] > 0.02)) {
						note = ~freqToMIDI.(freq);
						fftNotes = fftNotes.add(note);
						// Scale velocity between 0.2 and 0.9
						fftVelocities = fftVelocities.add(mags[i].linlin(0.02, 1.0, 0.2, 0.9));
					};
				});

				// Execute the callback to return analysis results
				if(callback.notNil) {
					callback.value(fftNotes, fftVelocities);
				} {
					// Using shorter latency for more responsiveness
					~processPeaksWithLatency.value(freqs, mags, 0.02);
				};
			});
		};

		// Function to process combined analysis - IMPROVED FOR GLISSANDO
		~processCombinedAnalysis = {|pitchFreqs, pitchAmps, flux|
			var pitchNotes, pitchVelocities, fftFreqs, fftMags;
			var combinedNotes, combinedVelocities;
			var notesToTurnOff, newNotes, noteIdx, i;
			var currentTime, noteTimestamp;
			var stableNotes;

			// Use the language-side variables instead of reading from buses
			var pitchAmount = ~pitchAmountValue;
			var fftAmount = ~fftAmountValue;

			// Initialize arrays
			pitchNotes = [];
			pitchVelocities = [];
			fftFreqs = Array.fill(~numFreqsToTrack, 0);
			fftMags = Array.fill(~numFreqsToTrack, 0);

			// Process pitch data with type safety - optimized for glissando detection
			if (pitchAmount.isNumber) {
				if (pitchAmount > 0.01) {
					pitchFreqs.do({|freq, i|
						var note, velocity;

						// Multiple safe checks for each value
						if (freq.notNil) {
							if (freq.isNumber) {
								if (freq > 0) {
									if (pitchAmps[i].notNil) {
										if (pitchAmps[i].isNumber) {
											if (pitchAmps[i] > 0.01) {
												// For primary frequency
												if (i == 0) {
													velocity = 0.5;  // Default velocity

													// Handle glissando only if we have previous value
													if (~lastDetectedFreq.notNil) {
														if (~lastDetectedFreq.isNumber) {
															if (~lastDetectedFreq > 0) {
																var change = abs(freq - ~lastDetectedFreq);
																// Higher velocity for faster changes
																velocity = min(0.9, 0.4 + (change * 10));
															}
														}
													};

													// Always update last frequency
													~lastDetectedFreq = freq;

													// Generate note
													note = ~freqToMIDI.(freq);
													velocity = velocity * pitchAmount;
												} {
													// For harmonics, use normal mapping
													note = ~freqToMIDI.(freq);
													velocity = pitchAmps[i].linlin(0.01, 1.0, 0.2, 0.9) * pitchAmount;
												};

												// Save note and velocity
												pitchNotes = pitchNotes.add(note);
												pitchVelocities = pitchVelocities.add(velocity);
											}
										}
									}
								}
							}
						}
					});
				}
			};

			// Process FFT data - separate completely from pitch processing
			if (fftAmount.notNil && fftAmount.isNumber && (fftAmount > 0.01)) {
				// Analyze the FFT buffer
				~analyzeEnhancedFFT.value(flux, { |fftNotesArray, fftVelocitiesArray|
					var combined = Dictionary.new;

					// Combine notes from both methods
					// First, add pitch notes
					pitchNotes.do({|note, i|
						combined[note.asInteger] = pitchVelocities[i];
					});

					// Then add or blend FFT notes
					fftNotesArray.do({|note, i|
						var vel = fftVelocitiesArray[i] * fftAmount;
						if(combined.includesKey(note.asInteger)) {
							// If note exists from pitch analysis, take the max velocity
							combined[note.asInteger] = max(combined[note.asInteger], vel);
						} {
							combined[note.asInteger] = vel;
						};
					});

					// Convert dictionary to arrays
					combinedNotes = [];
					combinedVelocities = [];
					combined.keysValuesDo({|note, vel|
						combinedNotes = combinedNotes.add(note);
						combinedVelocities = combinedVelocities.add(vel);
					});

					// Apply note stability through history tracking
					stableNotes = ~updateNoteHistory.(combinedNotes);

					// Build final note list with stable notes only
					combinedNotes = stableNotes;
					combinedVelocities = stableNotes.collect({|note|
						combined[note] ? 0.5;  // Default to medium velocity if missing
					});

					// Process these combined notes with shorter latency for better responsiveness
					~processNotesWithLatency.value(combinedNotes, combinedVelocities, 0.02);
				});
			} {
				// If FFT weight is minimal, just use pitch notes
				stableNotes = ~updateNoteHistory.(pitchNotes);

				// Only use stable notes
				pitchNotes = stableNotes;
				pitchVelocities = stableNotes.collect({|note|
					var idx = pitchNotes.indexOf(note);
					if (idx.notNil) {
						pitchVelocities[idx]
					} {
						0.5  // Default to medium velocity if missing
					};
				});

				~processNotesWithLatency.value(pitchNotes, pitchVelocities, 0.02);
			};
		};

		// Common function to process peaks for both FFT and Pitch methods
		~processPeaks = {|freqs, mags|
			var notes, strongNotes, notesToTurnOff, newNotes, noteIndex, velocity;

			// Map frequencies to MIDI notes with integer conversion
			notes = freqs.collect({|freq|
				if(freq > 0) { ~freqToMIDI.(freq) } { nil }
			}).select({|item| item.notNil });

			// Filter notes by amplitude (only keep strong peaks)
			strongNotes = [];
			notes.do({|note, i|
				// Lower threshold for more detection
				if(mags[i] > 0.02) {
					strongNotes = strongNotes.add(note);
				}
			});

			// Debug - show what was detected (uncomment if needed)
			// if(notes.size > 0) {
			//     "Detected notes: %".format(notes).postln;
			//     "Filtered strong notes: %".format(strongNotes).postln;
			// };

			// Find notes that need to be turned off (were playing but aren't now)
			if(~prevNotes.notNil) {
				notesToTurnOff = ~prevNotes.difference(strongNotes);
				if(notesToTurnOff.size > 0) {
					"Turning off notes: %".format(notesToTurnOff).postln;
					notesToTurnOff.do({|note|
						~sendNoteOffToKlavierautomat.(note);
					});
				};
			};

			// Send note-on messages for new notes
			newNotes = strongNotes.difference(~prevNotes ? []);
			if(newNotes.size > 0) {
				"Turning on new notes: %".format(newNotes).postln;
				newNotes.do({|note|
					noteIndex = notes.indexOf(note);
					// Scale velocity to 0.2-0.9 range for better dynamic range
					velocity = mags[noteIndex].linlin(0.02, 1.0, 0.2, 0.9);
					~sendNoteToKlavierautomat.(note, velocity);
				});
			};

			// Update the previous notes collection
			~prevNotes = strongNotes;
		};

		// Process peaks with latency to prevent note flickering during rapid changes
		~processPeaksWithLatency = {|freqs, mags, latency=0|
			var notes, strongNotes, notesToTurnOff, newNotes, noteIndex, velocity;
			var currentTime, noteTimestamp;

			// Initialize note buffer if needed
			if(~noteBuffer.isNil) {
				~noteBuffer = Dictionary.new;
			};

			currentTime = SystemClock.seconds;

			// Map frequencies to MIDI notes with safety checks
			notes = freqs.collect({|freq|
				if(freq.isNumber && (freq > 0)) { ~freqToMIDI.(freq) } { nil }
			}).select({|item| item.notNil });

			// Filter notes by amplitude (only keep strong peaks)
			strongNotes = [];
			notes.do({|note, i|
				// Lower threshold for more detection
				if(i < mags.size && mags[i].isNumber && mags[i] > 0.02) {
					strongNotes = strongNotes.add(note);
				}
			});

			// Debug - show what was detected with fewer messages
			// if((notes.size > 0) && (0.2.coin)) { // Only print ~20% of the time to avoid flooding
			//     "Detected notes: %".format(notes).postln;
			//     "Filtered strong notes: %".format(strongNotes).postln;
			// };

			// Find notes that need to be turned off
			if(~prevNotes.notNil) {
				notesToTurnOff = ~prevNotes.difference(strongNotes);

				if(notesToTurnOff.size > 0) {
					notesToTurnOff.do({|note|
						// Safety check: ensure note is not nil
						if(note.notNil) {
							// Get the timestamp safely (defaults to 0 if not found)
							noteTimestamp = ~noteBuffer[note] ? 0;

							// Use minimum duration to prevent quick note-offs
							if((currentTime - noteTimestamp) < max(latency, ~minimumNoteDuration)) {
								// Keep the note in the buffer - too recent to turn off
							} {
								// Turn off notes that have been gone for longer than the latency period
								~sendNoteOffToKlavierautomat.(note);
								// Record when we turned the note off for debouncing
								~noteDebounce[note] = currentTime;
								~noteBuffer.removeAt(note); // Clean up buffer
							};
						};
					});
				};
			};

			// Send note-on messages for new notes
			newNotes = strongNotes.difference(~prevNotes ? []);
			if(newNotes.size > 0) {
				"Turning on new notes: %".format(newNotes).postln;
				newNotes.do({|note|
					var idx = notes.indexOf(note);
					var lastOffTime = ~noteDebounce[note] ? 0;

					// Add debounce to prevent rapid on/off cycling
					if(idx.notNil && mags[idx].notNil &&
						((currentTime - lastOffTime) > ~debouncePeriod)) {
						// Scale velocity to 0.2-0.9 range for better dynamic range
						velocity = mags[idx].linlin(0.02, 1.0, 0.2, 0.9);
						~sendNoteToKlavierautomat.(note, velocity);

						// Add to the buffer with current timestamp
						~noteBuffer[note] = currentTime;
					};
				});
			};

			// Update the previous notes collection
			~prevNotes = strongNotes;
		};

		// Modified version of processPeaksWithLatency for combined notes - IMPROVED FOR GLISSANDO
		// Modified version of processNotesWithLatency for combined notes - IMPROVED FOR GLISSANDO
		~processNotesWithLatency = {|notes, velocities, latency=0|
			var notesToTurnOff, newNotes, currentTime, noteTimestamp;
			var timeSinceLastMessage;

			// Initialize note buffer if needed
			if(~noteBuffer.isNil) {
				~noteBuffer = Dictionary.new;
			};

			currentTime = SystemClock.seconds;
			timeSinceLastMessage = currentTime - ~lastNoteMessageTime;

			// Only process notes if enough time has passed since last message
			if(timeSinceLastMessage >= ~noteMessageInterval) {
				// Safety check for nil notes
				notes = notes ? [];
				velocities = velocities ? [];

				// Ensure all notes are integers
				notes = notes.collect(_.asInteger);

				// Debug - show what was detected with fewer messages
				// if((notes.size > 0) && (0.2.coin)) { // Only print ~20% of the time to avoid flooding
				//     "Combined notes: %".format(notes).postln;
				// };

				// Find notes that need to be turned off
				if(~prevNotes.notNil) {
					notesToTurnOff = ~prevNotes.difference(notes);

					if(notesToTurnOff.size > 0) {
						notesToTurnOff.do({|note|
							// Safety check: ensure note is not nil
							if(note.notNil) {
								// Get the timestamp safely (defaults to 0 if not found)
								noteTimestamp = ~noteBuffer[note] ? 0;

								// Use minimum duration to prevent quick note-offs
								if((currentTime - noteTimestamp) < max(latency, ~minimumNoteDuration)) {
									// Keep the note in the buffer - minimum duration not reached
								} {
									// Turn off notes that have been gone for longer than the minimum period
									~sendNoteOffToKlavierautomat.(note);
									// Record when we turned the note off for debouncing
									~noteDebounce[note] = currentTime;
									~noteBuffer.removeAt(note); // Clean up buffer
								};
							};
						});
					};
				};

				// Send note-on messages for new notes
				newNotes = notes.difference(~prevNotes ? []);
				if(newNotes.size > 0) {
					"Turning on new notes: %".format(newNotes).postln;
					newNotes.do({|note|
						var idx = notes.indexOf(note);
						var lastOffTime = ~noteDebounce[note] ? 0;

						// Add debounce to prevent rapid on/off cycling
						if(idx.notNil && velocities[idx].notNil &&
							((currentTime - lastOffTime) > ~debouncePeriod)) {
							// Send note with velocity
							~sendNoteToKlavierautomat.(note, velocities[idx]);

							// Add to the buffer with current timestamp
							~noteBuffer[note] = currentTime;
						};
					});
				};

				// Update the previous notes collection
				~prevNotes = notes;

				// Update the last message time
				~lastNoteMessageTime = currentTime;
			};
		};

		~processPolyPitchData = {|freqs, saliences, numVoices|
			var notes, velocities, stableNotes;
			var currentTime, noteTimestamp;

			// Initialize arrays
			notes = [];
			velocities = [];

			// Process detected frequencies
			freqs.do({|freq, i|
				var note, velocity;

				// Skip if beyond detected voice count or frequency is invalid
				if(i < numVoices && freq.notNil && freq.isNumber && freq > 0) {
					note = ~freqToMIDI.(freq);

					// Use salience as base for velocity calculation
					// PolyPitch salience is typically 0.0 to 1.0
					// Scale to reasonable velocity range (0.2-0.9)
					velocity = saliences[i].linlin(0.1, 1.0, 0.3, 0.9);

					// Special processing for first voice - track glissando
					if(i == 0 && ~lastDetectedFreq.notNil) {
						var change = abs(freq - ~lastDetectedFreq);

						// Calculate velocity based on rate of frequency change
						// Higher velocity for faster changes (better for glissando)
						if(change > 0.1) {  // Only adjust if significant change
							var glissVelocity = ~mapGlissandoVelocity.(freq, ~lastDetectedFreq);
							velocity = max(velocity, glissVelocity);  // Use whichever is stronger
						};
					};

					// Update last detected frequency
					if(i == 0) {
						~lastDetectedFreq = freq;
					};

					// Add to output arrays
					notes = notes.add(note);
					velocities = velocities.add(velocity);
				};
			});

			// Apply note stability through history tracking for more consistent output
			stableNotes = ~updateNoteHistory.(notes);

			// Only use stable notes
			notes = stableNotes;
			velocities = stableNotes.collect({|note|
				var idx = notes.indexOf(note);
				if(idx.notNil) {
					velocities[idx]
				} {
					0.5  // Default to medium velocity if missing
				};
			});

			// Process notes with latency compensation
			// Using shorter latency (0.02) for more responsive tracking
			~processNotesWithLatency.value(notes, velocities, 0.02);
		};

		~sendPedalToKlavierautomat = {|pedalValue|
			var msg;

			// Ensure value is between 0 and 1
			pedalValue = pedalValue.clip(0, 1);

			msg = ["/pedal", pedalValue];
			~oscClient.sendMsg("/pedal", pedalValue);
			"OSC Pedal: % -> %".format(~oscClient.ip, msg).postln;
		};
	);

	// === OSC LISTENERS ===
	(
		// Handler for basic FFT analysis ready notification
		OSCdef(\fftDataReady, {
			// When the FFT data is ready, analyze the magnitude buffer
			~analyzeMagBuffer.value;
		}, '/fft_data_ready');

		// Handler for enhanced FFT analysis
		OSCdef(\enhancedFftReady, {|msg|
			var flux = msg[3];
			// When the enhanced FFT data is ready, analyze the buffer
			~analyzeEnhancedFFT.value(flux);
		}, '/enhanced_fft_ready');

		// Handler for Pitch analysis data
		OSCdef(\pitchListener, {|msg|
			var frequencies, amplitudes, numPeaks;

			numPeaks = ~numFreqsToTrack;

			// Extract frequencies and amplitudes from message
			frequencies = Array.newFrom(msg[3..(numPeaks+2)]);
			amplitudes = Array.newFrom(msg[(numPeaks+3)..(2*numPeaks+2)]);

			// Process these frequencies and amplitudes
			~processPeaks.value(frequencies, amplitudes);

		}, '/pitch_analysis');

		// Handler for combined analysis data
		OSCdef(\combinedListener, {|msg|
			var pitchFrequencies, pitchAmplitudes, flux, numPeaks;

			numPeaks = ~numFreqsToTrack;

			// Extract pitch data and flux from message
			pitchFrequencies = Array.newFrom(msg[3..(numPeaks+2)]);
			pitchAmplitudes = Array.newFrom(msg[(numPeaks+3)..(2*numPeaks+2)]);
			flux = msg[2*numPeaks+3];

			// Process both pitch data and FFT data in parallel
			~processCombinedAnalysis.value(pitchFrequencies, pitchAmplitudes, flux);

		}, '/combined_analysis');

		// Handler for PolyPitch
		OSCdef(\polyPitchListener, {|msg|
			var frequencies, amplitudes, numVoices, numPeaks;

			numPeaks = ~numFreqsToTrack;

			// Extract data from message
			frequencies = Array.newFrom(msg[3..(numPeaks+2)]);
			amplitudes = Array.newFrom(msg[(numPeaks+3)..(2*numPeaks+2)]);
			numVoices = msg[2*numPeaks+3];  // Last value is the voice count

			// Process frequencies and amplitudes
			// Higher salience values in PolyPitch typically indicate more reliable detection
			~processPolyPitchData.value(frequencies, amplitudes, numVoices);

		}, '/polypitch_analysis');

		OSCdef(\superCombinedListener, {
			|msg|
			var pitchFreq, hasFreq, pitchAmp, numPolyVoices;
			var polyFreqs, polySaliences;
			var fftNotes, fftVelocities;
			var combinedNotes, combinedVelocities;
			var pitchAmount, fftAmount, polyPitchAmount;
			var note, velocity, change, glissVelocity;
			var polyNotes, polyVelocities;
			var noteDict, stableNotes;
			var currentTime, processPitch, processPoly, processFft;

			currentTime = SystemClock.seconds;

			// Check timing for each mode separately
			processPitch = (currentTime - ~lastPitchMessageTime) >= ~pitchNoteMessageInterval;
			processPoly = (currentTime - ~lastPolyMessageTime) >= ~polyNoteMessageInterval;
			processFft = (currentTime - ~lastFftMessageTime) >= ~fftNoteMessageInterval;

			// Extract weights from language-side variables
			pitchAmount = ~pitchAmountValue;
			fftAmount = ~fftAmountValue;
			polyPitchAmount = ~polyPitchAmountValue;

			// Extract data from message
			pitchFreq = msg[3];
			hasFreq = msg[4];
			pitchAmp = msg[5];
			numPolyVoices = msg[6];

			// Extract PolyPitch data
			polyFreqs = Array.newFrom(msg[7..10]);  // First 4 frequencies
			polySaliences = Array.newFrom(msg[11..14]);  // First 4 saliences

			// Initialize note collections
			combinedNotes = [];
			combinedVelocities = [];

			// Process Pitch data if weight is significant AND it's time to process pitch data
			if(~safeGreaterThan.(pitchAmount, 0.05) && ~safeGreaterThan.(hasFreq, 0.5) &&
				~safeGreaterThan.(pitchAmp, 0.01) && processPitch) {

				note = ~freqToMIDI.(pitchFreq);
				velocity = pitchAmp.linlin(0.01, 1.0, 0.3, 0.9) * pitchAmount;

				// Handle glissando
				if(~lastDetectedFreq.notNil) {
					if(~lastDetectedFreq.isNumber) {
						if(~lastDetectedFreq > 0) {
							change = abs(pitchFreq - ~lastDetectedFreq);
							if(~safeGreaterThan.(change, 0.1)) {
								glissVelocity = ~mapGlissandoVelocity.(pitchFreq, ~lastDetectedFreq) * pitchAmount;
								velocity = max(velocity, glissVelocity);
							};
						};
					};
				};
				~lastDetectedFreq = pitchFreq;

				// Add pitch note to the combined collection
				combinedNotes = [note];
				combinedVelocities = [velocity];

				// Update last pitch processing time
				~lastPitchMessageTime = currentTime;
			};

			// Process PolyPitch data if weight is significant AND it's time to process poly data
			if(~safeGreaterThan.(polyPitchAmount, 0.05) && processPoly) {
				polyNotes = [];
				polyVelocities = [];

				// Process poly pitch data
				polyFreqs.do({|freq, i|
					// First, ensure freq is a number
					if(i < numPolyVoices && freq.notNil && freq.isNumber) {
						// Then use safeGreaterThan for the comparison
						if(~safeGreaterThan.(freq, 0)) {
							note = ~freqToMIDI.(freq);
							if(i < polySaliences.size && polySaliences[i].notNil && polySaliences[i].isNumber) {
								velocity = polySaliences[i].linlin(0.1, 1.0, 0.3, 0.9) * polyPitchAmount;
								polyNotes = polyNotes.add(note);
								polyVelocities = polyVelocities.add(velocity);
							};
						};
					};
				});

				// Add to combined collection
				combinedNotes = combinedNotes ++ polyNotes;
				combinedVelocities = combinedVelocities ++ polyVelocities;

				// Update last polypitch processing time
				~lastPolyMessageTime = currentTime;
			};

			// Process FFT data if weight is significant AND it's time to process FFT data
			if(~safeGreaterThan.(fftAmount, 0.05) && processFft) {
				// Process the FFT data from the magBuffer
				~analyzeEnhancedFFT.value(nil, {|fftNotesArray, fftVelocitiesArray|
					// Need to redeclare variables for this function scope
					var noteDict, existingVel, newVel;

					// Check if arrays are valid
					if(fftNotesArray.notNil && fftVelocitiesArray.notNil) {
						// Scale FFT velocities by FFT weight
						fftVelocitiesArray = fftVelocitiesArray.collect({|vel|
							if(vel.isNumber, { vel * fftAmount }, { 0 });
						});

						// Add to combined collection
						combinedNotes = combinedNotes ++ fftNotesArray;
						combinedVelocities = combinedVelocities ++ fftVelocitiesArray;

						// Create a dictionary to resolve duplicate notes with strongest velocity
						noteDict = Dictionary.new;

						// Filter duplicates by choosing highest velocity
						combinedNotes.do({|note, i|
							if(i < combinedVelocities.size) {
								existingVel = noteDict[note];
								newVel = combinedVelocities[i];

								if(existingVel.isNil || ~safeGreaterThan.(newVel, existingVel)) {
									noteDict[note] = newVel;
								};
							};
						});

						// Convert dictionary back to arrays
						combinedNotes = [];
						combinedVelocities = [];

						noteDict.keysValuesDo({|note, vel|
							combinedNotes = combinedNotes.add(note);
							combinedVelocities = combinedVelocities.add(vel);
						});

						// Apply note stability through history tracking
						combinedNotes = ~updateNoteHistory.(combinedNotes);
						combinedVelocities = combinedNotes.collect({|note|
							noteDict[note] ? 0.5;  // Default to medium velocity if missing
						});

						// Process the final combined notes
						~processNotesWithLatency.value(combinedNotes, combinedVelocities, 0.02);
					};
				});

				// Update last FFT processing time
				~lastFftMessageTime = currentTime;
			} {
				// If not using FFT, process the notes we have so far
				// Apply note stability through history tracking
				stableNotes = ~updateNoteHistory.(combinedNotes);

				// Create a dictionary for note-to-velocity mapping
				noteDict = Dictionary.new;
				combinedNotes.do({|note, i|
					if(i < combinedVelocities.size) {  // Safety check
						noteDict[note] = combinedVelocities[i];
					};
				});

				// Process only stable notes
				combinedNotes = stableNotes;
				combinedVelocities = stableNotes.collect({|note|
					noteDict[note] ? 0.5;  // Default to medium velocity if missing
				});

				~processNotesWithLatency.value(combinedNotes, combinedVelocities, 0.02);
			};
		}, '/super_combined_analysis');


	);

	// === CONTROL FUNCTIONS ===
	(
		// Function to switch analysis method
		~setAnalysisMethod = {|method|
			if((method == \fft) || (method == \pitch) || (method == \enhancedFft) ||
				(method == \combined) || (method == \polyPitch) || (method == \superCombined)) {
				~analysisMethod = method;
				"Analysis method set to %".format(method).postln;

				// Restart analysis if already running
				if(~analysisRoutine.notNil) {
					~stopAnalysis.value;
					~startAnalysis.value;
				};
			} {
				"Invalid method. Use \\fft, \\pitch, \\enhancedFft, \\combined, or \\polyPitch.".postln;
			};
		};

		// Create the routine to control analysis rate
		~startAnalysis = {
			if(~analysisRoutine.notNil) {
				~analysisRoutine.stop;
				"Stopping previous analysis routine.".postln;
			};

			// Free any existing synth
			if(~analyzerSynth.notNil) {
				~analyzerSynth.free;
				~analyzerSynth = nil;
			};

			// Initialize or reset the note buffer for enhanced tracking
			~noteBuffer = Dictionary.new;
			~noteDebounce = Dictionary.new;
			~noteHistory = Dictionary.new;
			~prevNotes = [];
			~lastDetectedFreq = nil;

			// Start the appropriate analyzer with a higher priority to ensure it runs after sound generators
			~analyzerSynth = switch(~analysisMethod,
				\fft, { Synth.tail(1, \fftAnalyzer) },
				\pitch, { Synth.tail(1, \pitchAnalyzer) },
				\enhancedFft, { Synth.tail(1, \enhancedFftAnalyzer) },
				\combined, { Synth.tail(1, \combinedAnalyzer) },
				\polyPitch, { Synth.tail(1, \polyPitchAnalyzer) },
				\superCombined, { Synth.tail(1, \combinedWithPolyPitch) }
			);

			"Created % analyzer synth.".format(~analysisMethod).postln;
			"OSC client configured for IP: % port: %".format(~klavierautomatIP, ~klavierautomatPort).postln;
			"Sending messages to address pattern: %".format(~klavierautomatAddress).postln;
			"Analyzer is monitoring the MAIN OUTPUT (not inputs).".postln;

			if(~analysisMethod == \combined) {
				"Slider 6 controls pitch analysis amount, Slider 7 controls FFT analysis amount.".postln;
			};

			if(~analysisMethod == \superCombined) {
				"SuperCombined mode active:".postln;
				"  Slider 6: Pitch analysis amount - good for monophonic content and glissandi".postln;
				"  Slider 7: FFT analysis amount - good for noisy/percussive content".postln;
				"  Slider 8: PolyPitch amount - good for polyphonic content".postln;
			};

			~analysisRoutine = Routine({
				loop {
					// Update the slider buses on each cycle
					~updateSliderBuses.value;

					// Use different knobs for each mode's timing
					~pitchNoteMessageInterval = ~knobValue.(63, 1e-4, 2, \exp);  // Knob 63 for pitch
					~fftNoteMessageInterval = ~knobValue.(73, 1e-4, 2, \exp);    // Knob 64 for FFT
					~polyNoteMessageInterval = ~knobValue.(83, 1e-4, 2, \exp);   // Knob 65 for polypitch

					// Each update, wait for the specified time
					~updateRate.wait;
				};
			}).play;

			"Started analysis routine at % Hz with % method.".format(
				1/~updateRate,
				~analysisMethod
			).postln;
		};

		// Function to stop the analysis routine
		~stopAnalysis = {
			if(~analysisRoutine.notNil) {
				~analysisRoutine.stop;
				~analysisRoutine = nil;

				// Free the synth
				if(~analyzerSynth.notNil) {
					~analyzerSynth.free;
					~analyzerSynth = nil;
					"Analyzer synth freed.".postln;
				};

				// Turn off any currently playing notes
				if(~prevNotes.notNil) {
					~prevNotes.do({|note|
						~sendNoteOffToKlavierautomat.(note);
					});
					~prevNotes = nil;
				};

				"Stopped analysis routine.".postln;
			} {
				"No analysis routine running.".postln;
			};
		};

		// Function to change the update rate
		~setUpdateRate = {|rate|
			~updateRate = rate;
			"Analysis rate set to % seconds (% Hz).".format(rate, 1/rate).postln;

			// Restart the analysis routine if it's already running
			if(~analysisRoutine.notNil) {
				// Store current analyzer
				var currentMethod = ~analysisMethod;

				// Stop current analysis
				~stopAnalysis.value;

				// Set the new rate
				~updateRate = rate;

				// Restart with same method
				~analysisMethod = currentMethod;
				~startAnalysis.value;
			};
		};

		// Function to clean up when done
		~cleanup = {
			~stopAnalysis.value;

			// Free the buffers
			~fftBuffer.free;
			~magBuffer.free;

			// Clear the note buffer
			~noteBuffer = nil;
			~noteDebounce = nil;
			~noteHistory = nil;
			~lastDetectedFreq = nil;

			"Cleaned up resources.".postln;
		};
	);

	"Setup complete. Use ~startAnalysis.value to begin.".postln;
	"Default analysis method is: %.".format(~analysisMethod).postln;
	"Use ~setAnalysisMethod.(\\fft), ~setAnalysisMethod.(\\pitch), ~setAnalysisMethod.(\\enhancedFft), or ~setAnalysisMethod.(\\combined) to switch methods.".postln;
	"When using the combined method, Slider 6 controls pitch analysis amount, Slider 7 controls FFT analysis amount.".postln;
	"For best glissando tracking, use \\pitch mode or the combined mode with slider 6 high and slider 7 low.".postln;
};
)


// ===== EXAMPLE USAGE =====

// Start the analyzer with the default method (combined FFT+Pitch)
~startAnalysis.value;

// For best glissando tracking, use pitch detection
~setAnalysisMethod.(\pitch);

// Or use combined with high pitch sensitivity
~setAnalysisMethod.(\combined);

// Set a fast update rate for more responsive tracking
~setUpdateRate.value(0.03);  // 33 Hz

// Test sending specific notes to the Klavierautomat
~sendNoteToKlavierautomat.value(60, 0.7);  // Middle C, velocity 0.7
~sendNoteOffToKlavierautomat.value(60);    // Turn off Middle C

// Stop the analyzer
~stopAnalysis.value;

// Clean up resources when completely done
~cleanup.value;



// Send pedal message
a = NetAddr("192.168.10.1", 7000);
a.sendMsg("/note", 60, 0.5);
a.sendMsg("/note", 60, 0);
a.sendMsg("/pedal", 0);

a.sendMsg("/panic");