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
		~analysisMethod = \combined;     // \fft, \pitch, \enhancedFft, or \combined

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
		~pitchAmountValue = 0.5;         // Language-side variable for pitch amount
		~fftAmountValue = 0.5;           // Language-side variable for FFT amount

		// Note stability through history tracking
		~noteHistory = Dictionary.new;   // Track detection history for each note
		~historyLength = 2;              // Number of frames to track
		~requiredCount = 1;              // Required detections to trigger a note

		// Create control buses for the slider values
		~pitchAmountBus = Bus.control(s, 1).set(0.5);  // Default to 0.5
		~fftAmountBus = Bus.control(s, 1).set(0.5);    // Default to 0.5

		// Function to update the slider buses from the MIDI sliders
		~updateSliderBuses = {
			// Get slider values
			var pitchAmount = ~sliderValue.value(6);
			var fftAmount = ~sliderValue.value(7);

			// Store values in language-side variables
			~pitchAmountValue = pitchAmount;
			~fftAmountValue = fftAmount;

			// Update the buses for the synth
			~pitchAmountBus.set(pitchAmount);
			~fftAmountBus.set(fftAmount);
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
			in = InFeedback.ar(0, 2);  // Listen to output bus 0 (stereo)
			mono = Mix(in) / 2;        // Convert to mono
			chain = FFT(~fftBuffer, mono);
			trig = Impulse.kr(30);     // Faster trigger rate (30 Hz) for better tracking

			// Store magnitudes in the magBuffer using PV_MagBuffer
			chain = PV_MagBuffer(chain, ~magBuffer);

			// Trigger a notification when analysis is ready
			SendReply.kr(trig, '/fft_data_ready');

			// Silent output
			Out.ar(0, 0);
		}).add;

		//-----------------------------------------------------
		// METHOD 2: Pitch detection (time domain)
		//-----------------------------------------------------
		SynthDef(\pitchAnalyzer, {
			var in, mono, freq, hasFreq, amp, detectedFreqs, detectedAmps, trigger;
			var i, harmonic, harmAmp;

			// All variables must be declared at the beginning
			in = InFeedback.ar(0, 2);     // Listen to output bus 0 (stereo)
			mono = Mix(in) / 2;           // Convert to mono
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
		}).add;

		//-----------------------------------------------------
		// METHOD 3: Enhanced FFT spectral analysis with better tracking
		//-----------------------------------------------------
		SynthDef(\enhancedFftAnalyzer, {
			var in, mono, chain, trig;
			var centroid, flatness, flux;

			// All variables must be declared at the beginning
			in = InFeedback.ar(0, 2);    // Listen to output bus 0 (stereo)
			mono = Mix(in) / 2;          // Convert to mono

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
			Out.ar(0, 0);
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
			in = InFeedback.ar(0, 2);    // Listen to output bus 0 (stereo)
			mono = Mix(in) / 2;          // Convert to mono

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
			Out.ar(0, 0);
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
		~processNotesWithLatency = {|notes, velocities, latency=0|
			var notesToTurnOff, newNotes, currentTime, noteTimestamp;

			// Initialize note buffer if needed
			if(~noteBuffer.isNil) {
				~noteBuffer = Dictionary.new;
			};

			currentTime = SystemClock.seconds;

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
	);

	// === CONTROL FUNCTIONS ===
	(
		// Function to switch analysis method
		~setAnalysisMethod = {|method|
			if((method == \fft) || (method == \pitch) || (method == \enhancedFft) || (method == \combined)) {
				~analysisMethod = method;
				"Analysis method set to %".format(method).postln;

				// Restart analysis if already running
				if(~analysisRoutine.notNil) {
					~stopAnalysis.value;
					~startAnalysis.value;
				};
			} {
				"Invalid method. Use \\fft, \\pitch, \\enhancedFft, or \\combined.".postln;
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
				\combined, { Synth.tail(1, \combinedAnalyzer) }
			);

			"Created % analyzer synth.".format(~analysisMethod).postln;
			"OSC client configured for IP: % port: %".format(~klavierautomatIP, ~klavierautomatPort).postln;
			"Sending messages to address pattern: %".format(~klavierautomatAddress).postln;
			"Analyzer is monitoring the MAIN OUTPUT (not inputs).".postln;

			if(~analysisMethod == \combined) {
				"Slider 6 controls pitch analysis amount, Slider 7 controls FFT analysis amount.".postln;
			};

			~analysisRoutine = Routine({
				loop {
					// Update the slider buses on each cycle
					~updateSliderBuses.value;

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