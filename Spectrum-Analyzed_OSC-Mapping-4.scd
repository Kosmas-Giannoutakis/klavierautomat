// SuperCollider Frequency Analyzer to Klavierautomat OSC Controller
// Streamlined version focused only on the combined with PolyPitch functionality
// Optimized for tracking glissandi and polyphonic content

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

		// Parameters for combined analysis
		~pitchWeight = 0.5;              // Initial weight for pitch analysis (0-1)
		~fftWeight = 0.5;                // Initial weight for FFT analysis (0-1)

		// Language-side variables for slider values
		~pitchAmountValue = 0.3;         // Language-side variable for pitch amount
		~fftAmountValue = 0.7;           // Language-side variable for FFT amount
		~polyPitchAmountValue = 0.5;     // Language-side variable for PolyPitch amount
		~bassSensitivityValue = 0.5;     // Language-side variable for bass sensitivity
		~bassBoostValue = 0.5;           // Language-side variable for bass boost/emphasis

		// Note stability through history tracking
		~noteHistory = Dictionary.new;   // Track detection history for each note
		~historyLength = 2;              // Number of frames to track
		~requiredCount = 1;              // Required detections to trigger a note

		// Create control buses for the slider values
		~pitchAmountBus = Bus.control(s, 1).set(0.5);   // Default to 0.5
		~fftAmountBus = Bus.control(s, 1).set(0.5);     // Default to 0.5
		~polyPitchAmountBus = Bus.control(s, 1).set(0.5); // Default to 0.5
		~bassSensitivityBus = Bus.control(s, 1).set(0.5); // Default bass sensitivity: 0.5
		~bassBoostBus = Bus.control(s, 1).set(0.5);     // Default bass boost: 0.5

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
		~lastNoteMessageTime = 0;
		~noteMessageInterval = 0.001;

		// Function to update the slider buses from the MIDI sliders
		~updateSliderBuses = {
			// Keep the existing slider value readings
			var pitchAmount = ~sliderValue.value(6);
			var fftAmount = ~sliderValue.value(7);
			var polyPitchAmount = ~sliderValue.value(8);

			// Use knobs instead of sliders for bass sensitivity
			var bassSensitivity = ~knobValue.(71, 0, 1);  // Use knob 71 for bass sensitivity
			var bassBoost = ~knobValue.(72, 0, 1);        // Use knob 72 for bass boost/emphasis

			// Add pedal control from slider 4
			var pedalValue = ~sliderValue.value(4);

			// Store values in language-side variables
			~pitchAmountValue = pitchAmount;
			~fftAmountValue = fftAmount;
			~polyPitchAmountValue = polyPitchAmount;
			~bassSensitivityValue = bassSensitivity;
			~bassBoostValue = bassBoost;

			// Update the buses for the synth
			~pitchAmountBus.set(pitchAmount);
			~fftAmountBus.set(fftAmount);
			~polyPitchAmountBus.set(polyPitchAmount);
			~bassSensitivityBus.set(bassSensitivity);
			~bassBoostBus.set(bassBoost);
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

		~sendPedalToKlavierautomat = {|pedalValue|
			var msg;

			// Ensure value is between 0 and 1
			pedalValue = pedalValue.clip(0, 1);

			msg = ["/pedal", pedalValue];
			~oscClient.sendMsg("/pedal", pedalValue);
			"OSC Pedal: % -> %".format(~oscClient.ip, msg).postln;
		};
	);

	// === SYNTH DEFINITION ===
	(
		// Only keeping the PolyPitch combined analyzer
		SynthDef(\combinedWithPolyPitch, {
			var in, mono, chain, trig;
			var pitchFreq, hasFreq, pitchAmp;
			var polyPitchOut, numVoices;
			var pitchWeight, fftWeight, polyPitchWeight;
			var ampThreshValue = 0.01; // Fixed value instead of using knob
			var medianValue = 3; // Fixed value instead of using knob

			// Read weights from control buses
			pitchWeight = In.kr(~pitchAmountBus);
			fftWeight = In.kr(~fftAmountBus);
			polyPitchWeight = In.kr(~polyPitchAmountBus);

			// Input from main output bus
			in = InFeedback.ar(0, 8);
			mono = Mix.ar(in)/8;

			// Basic Pitch detection for monophonic parts and glissandi
			# pitchFreq, hasFreq = Pitch.kr(
				mono,
				initFreq: 200.0,
				minFreq: ~minFreq,
				maxFreq: ~maxFreq,
				ampThreshold: ampThreshValue,
				median: medianValue
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
	"SynthDef added to server.".postln;

	// === ANALYSIS FUNCTIONS ===
	(
		// Enhanced buffer analysis function with better peak detection and tracking
		~analyzeEnhancedFFT = {|flux, callback|
			var freqs, mags, peakThreshold, magArray, peaks, binIndex, freq;
			var spectralFlux, windowSize, isPeak, peakVal, binThreshold;
			var validPeaks, selectedPeaks, usedFreqs, isHarmonic, ratio, closestInteger;
			var fftNotes, fftVelocities;
			var bassSensitivity, bassBoost, bassBoostFactor, bassSensitivityFactor;
			var lowBinBoundary, midBinBoundary, highBinBoundary;

			// Get bass control values from the language-side variables
			bassSensitivity = ~bassSensitivityValue;  // Controls threshold (detection)
			bassBoost = ~bassBoostValue;              // Controls magnitude/velocity (emphasis)

			// Calculate adjustment factors
			// Higher sensitivity means lower threshold (more bass notes detected)
			bassSensitivityFactor = bassSensitivity.linlin(0, 1, 0.9, 0.1);
			// Higher boost means more emphasis on bass notes when playing
			bassBoostFactor = bassBoost.linexp(0, 1, 1.0, 4.0);

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

				// Define frequency band boundaries
				lowBinBoundary = (vals.size * 0.1).asInteger; // Lowest 10% is low bass
				midBinBoundary = (vals.size * 0.3).asInteger; // Up to 30% is mid
				highBinBoundary = (vals.size * 0.7).asInteger; // Up to 70% is high

				// Normal peak detection for tonal content with enhanced bass sensitivity
				// Improved peak detection - examine each bin in context
				for(windowSize, vals.size-(windowSize+1), { |i|
					isPeak = true;
					peakVal = vals[i];

					// Skip if peakVal is nil
					if(peakVal != nil) {
						// Apply frequency-dependent thresholds
						binThreshold = peakThreshold;

						// Adjust threshold based on frequency band and bass sensitivity
						if(i < lowBinBoundary) {
							// Low frequency (bass) gets significantly lower threshold based on sensitivity
							binThreshold = peakThreshold * bassSensitivityFactor;
						} {
							if(i < midBinBoundary) {
								// Mid-low frequency gets moderately lower threshold
								binThreshold = peakThreshold * (0.5 + (bassSensitivityFactor * 0.5));
							} {
								if(i < highBinBoundary) {
									// Mid-high frequency gets slight adjustment
									binThreshold = peakThreshold * 0.9;
								};
							};
						};

						// Only consider if above adjusted threshold
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
								// For bass frequencies, boost the magnitude by the bass boost factor
								// This gives more weight to lower frequencies in sorting
								if(i < midBinBoundary) {
									// Boost by a factor determined by the bass boost control
									peakVal = peakVal * (1 + ((1 - bassSensitivityFactor) * bassBoost));
								};

								// Add the peak to our collection
								peaks = peaks.add([i, peakVal]);
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

				// Convert frequencies to MIDI notes for FFT with enhanced bass velocity
				freqs.do({|freq, i|
					var note, velocity, lowNoteBoost, noteValue;

					// Lower threshold for more detection
					if(freq.isNumber && (freq > 0) && mags[i].isNumber && (mags[i] > 0.02)) {
						note = ~freqToMIDI.(freq);
						noteValue = note;

						// Calculate the low note boost factor based on MIDI note number
						// Lower notes get progressively more boost based on bassBoost parameter
						lowNoteBoost = if(noteValue < 48) {
							// Below C3 (MIDI 48), apply bass boost scaled by the bass boost parameter
							// The lower the note, the more boost it gets
							var noteDistance = (48 - noteValue);
							var boostFactor = noteDistance * 0.05 * bassBoostFactor;
							(1 + boostFactor)
						} {
							1 // No boost for higher notes
						};

						// Scale velocity between 0.2 and 0.9 with the low note boost
						velocity = mags[i].linlin(0.02, 1.0, 0.2, 0.9) * lowNoteBoost;
						velocity = velocity.clip(0.2, 0.9); // Keep within reasonable range

						fftNotes = fftNotes.add(note);
						fftVelocities = fftVelocities.add(velocity);
					};
				});

				// Execute the callback to return analysis results
				if(callback.notNil) {
					callback.value(fftNotes, fftVelocities);
				};
			});
		};

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
	);

	// === OSC LISTENERS ===
	(
		// Handler for super combined analysis data
		OSCdef(\superCombinedListener, {
			|msg|
			var pitchFreq, hasFreq, pitchAmp, numPolyVoices;
			var polyFreqs, polySaliences;
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

			// Start the analyzer synth
			~analyzerSynth = Synth.tail(1, \combinedWithPolyPitch);

			"Created combinedWithPolyPitch analyzer synth.".postln;
			"OSC client configured for IP: % port: %".format(~klavierautomatIP, ~klavierautomatPort).postln;
			"Sending messages to address pattern: %".format(~klavierautomatAddress).postln;
			"Analyzer is monitoring the MAIN OUTPUT (not inputs).".postln;

			"SuperCombined mode active:".postln;
			"  Knob 63: Pitch timing - controls how often pitch notes can change".postln;
			"  Knob 71: Bass detection sensitivity - increase to detect more low notes".postln;
			"  Knob 72: Bass emphasis/boost - increase to make bass notes louder".postln;
			"  Knob 73: FFT timing - controls how often FFT notes can change".postln;
			"  Knob 83: PolyPitch timing - controls how often polyphonic notes can change".postln;
			"  Slider 6: Pitch analysis amount - good for monophonic content and glissandi".postln;
			"  Slider 7: FFT analysis amount - good for noisy/percussive content".postln;
			"  Slider 8: PolyPitch amount - good for polyphonic content".postln;

			~analysisRoutine = Routine({
				loop {
					// Update the slider buses on each cycle
					~updateSliderBuses.value;

					// Use different knobs for each mode's timing
					~pitchNoteMessageInterval = ~knobValue.(63, 0.033, 2, \exp);  // Knob 63 for pitch timing
					~fftNoteMessageInterval = ~knobValue.(73, 0.033, 2, \exp);    // Knob 73 for FFT timing
					~polyNoteMessageInterval = ~knobValue.(83, 0.033, 2, \exp);   // Knob 83 for polypitch timing

					// Each update, wait for the specified time
					~updateRate.wait;
				};
			}).play;

			"Started analysis routine at % Hz.".format(1/~updateRate).postln;
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

		// Function to send panic (all notes off)
		~sendPanic = {
			var i;
			"PANIC - Turning off all notes".postln;
			// Send note off messages for all possible piano notes
			for(~minMIDINote, ~maxMIDINote, {|note|
				~sendNoteOffToKlavierautomat.(note);
			});
			// Also send the /panic OSC message
			~oscClient.sendMsg("/panic");
			"Sent panic message to Klavierautomat".postln;
		};
	);

	"Setup complete. Use ~startAnalysis.value to begin.".postln;
};
)


// ===== EXAMPLE USAGE =====

// Start the analyzer
~startAnalysis.value;

// Stop the analyzer
~stopAnalysis.value;

// Clean up resources when completely done
~cleanup.value;

// Send a panic message (all notes off)
~sendPanic.value;

// Test sending specific notes to the Klavierautomat
~sendNoteToKlavierautomat.value(60, 0.7);  // Middle C, velocity 0.7
~sendNoteOffToKlavierautomat.value(60);    // Turn off Middle C

// Send pedal message example
~sendPedalToKlavierautomat.value(0.5);  // Half pedal