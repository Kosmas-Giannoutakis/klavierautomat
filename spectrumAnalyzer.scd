// Direct FFT-based Spectrum Analyzer for 88 piano note frequencies
// Uses FFT chain processing for more accurate analysis

// Efficient Spectrum Analyzer for 88 piano note frequencies
// Uses a single FFT analysis and bin energy extraction

(
SynthDef(\spectrumAnalyzer, {
    // Declare all variables at the beginning
    var input, mono, baseFreq, noteFreqs;
    var fftSize, hopSize, bufnum, chain, phasechainMags;
    var binIndices, magnitudes;
    var i, freq, binIndex, energy, threshold, isPeak;

    // Analyze 8 output channels with normalization
    input = InFeedback.ar(0, 8) / ~volumeNormalization;

    // Mix down to mono
    mono = Mix(input) / 8;

    // Define piano note frequencies (A0 to C8)
    baseFreq = 27.5; // A0 (lowest piano note)
    noteFreqs = Array.fill(88, { |i|
        baseFreq * (2 ** (i / 12))
    });

    // FFT analysis setup
    fftSize = 4096;
    hopSize = 0.5; // Process at half rate for CPU efficiency
    bufnum = LocalBuf(fftSize);
    chain = FFT(bufnum, mono, hopSize, wintype: 1);

    // Square the magnitudes to get power values
    chain = PV_MagSquared(chain);

    // Apply some smoothing to the spectrum
    chain = PV_MagSmear(chain, 3);

    // For each piano note, extract the energy at the corresponding FFT bin
    noteFreqs.do { |freq, i|
		var narrowChain;
        // Calculate the FFT bin index for this frequency
        binIndex = (freq / SampleRate.ir * fftSize).round.asInteger;
        binIndex = binIndex.clip(1, fftSize/2 - 1);

        // Instead of trying to access the bin directly (which is challenging),
        // we'll create a specialized analysis focusing on energy around that bin
        energy = 0;

        // Use a combination of FFTPower and spectral filtering to approximate bin energy
        // We'll create a very narrow spectral filter around the target frequency
        narrowChain = PV_BrickWall(chain.copy, (binIndex-1)/(fftSize/2) - 1, (binIndex+1)/(fftSize/2));
        energy = FFTPower.kr(narrowChain) * 1000;

        // Ensure positive values
        energy = energy.abs;

        // Detect peaks with an appropriate threshold
        threshold = 50;
        isPeak = energy > threshold;

        // Send to control buses
        Out.kr(100 + i, energy);     // Energy for each piano note
        Out.kr(200 + i, isPeak);     // Boolean (1/0) for peak detection
    };

    // No audio output needed
    Out.ar(0, DC.ar(0!2));
}).add;
)

// Start the analyzer
(
~spectrumAnalyzer = Synth(\spectrumAnalyzer);
)

// Test the analyzer by posting tracked data continuously
(
// Declare all variables at the beginning
var r, allAmps, sorted, peakBins, noteIndex, amp, isPeak, freq;
var waitTime, noteFreqs, droneFreq, distances, closestIndex;
var closestFreq, droneAmp, isDronePeak;

// Set values
waitTime = 0.5; // Update interval in seconds

// Store the routine globally so it can be stopped from anywhere
~analyzerRoutine = Routine({
    inf.do { |j|
        ("Frame " ++ j).postln;

        // Read data from control buses
        allAmps = Array.fill(88, { |i|
            var bus1 = Bus(\control, 100 + i, 1, s);
            var bus2 = Bus(\control, 200 + i, 1, s);
            var amp = bus1.getSynchronous;
            var isPeak = bus2.getSynchronous > 0.5;
            [i, amp, isPeak]
        });

        // Sort by amplitude (highest first)
        sorted = allAmps.sort({ |a, b| a[1] > b[1] });

        // Show the top 10 active bins
        "Top 10 active frequency bins:".postln;
        sorted[0..9].do { |item|
            noteIndex = item[0];
            amp = item[1];
            isPeak = item[2];
            freq = 27.5 * (2 ** (noteIndex / 12));

            ("  Bin " ++ noteIndex ++ ": Freq " ++ freq.round(0.01) ++ " Hz, Amp: " ++
             amp.round(0.000001) ++ ", Peak: " ++ if(isPeak, "YES", "no")).postln;
        };

        // Count peaks
        peakBins = allAmps.select({ |item| item[2] });
        ("Total peaks detected: " ++ peakBins.size).postln;

        // Show peaks if any
        if(peakBins.size > 0) {
            "Peak frequencies:".postln;
            peakBins.do { |item|
                noteIndex = item[0];
                amp = item[1];
                freq = 27.5 * (2 ** (noteIndex / 12));

                ("  Bin " ++ noteIndex ++ ": Freq " ++ freq.round(0.01) ++ " Hz, Amp: " ++
                 amp.round(0.000001)).postln;
            };
        };

        // Display all bins with frequencies and amplitudes
        "".postln;
        "All frequency bins:".postln;
        allAmps.do { |item|
            noteIndex = item[0];
            amp = item[1];
            freq = 27.5 * (2 ** (noteIndex / 12));

            ("  Bin " ++ noteIndex ++ ": Freq " ++ freq.round(0.01) ++ " Hz, Amp: " ++
             amp.round(0.000001)).postln;
        };

        // Find the bin closest to 65 Hz and highlight it
        "".postln;
        "Drone analysis (65 Hz):".postln;
        noteFreqs = Array.fill(88, { |i| 27.5 * (2 ** (i / 12)) });
        droneFreq = 65;
        distances = noteFreqs.collect({ |f| (f - droneFreq).abs });
        closestIndex = distances.minIndex;
        closestFreq = noteFreqs[closestIndex];
        droneAmp = allAmps[closestIndex][1];
        isDronePeak = allAmps[closestIndex][2];

        ("  Bin " ++ closestIndex ++ ": Freq " ++ closestFreq.round(0.01) ++
         " Hz (closest to 65 Hz), Amp: " ++ droneAmp.round(0.000001) ++
         ", Peak: " ++ if(isDronePeak, "YES", "no")).postln;

        "-----------------------".postln;
        waitTime.wait;
    };
}).play;

// Instructions for stopping the analyzer posting
"To stop the analyzer posting, run: ~analyzerRoutine.stop;".postln;
)

// To stop just the posting (but keep the analyzer running):
~analyzerRoutine.stop;

// To stop the analyzer completely:
~spectrumAnalyzer.free;

