DDWSnippets.load(\SCTweets_mod1)

//Tweet by Batuhan Bozkurt (earslap)
//https://earslap.com/

~monitorBus = 51;

(Ndef(\untuned_note_ascending, {
	var mix, sig;
	var in=SoundIn.ar(0);
    var fb=LocalIn.ar(2);
    var wr=Write.ar(fb);
	var l1=FDLine.ar(wr, 3e-4, 80, 1.2);
	var l2=FDLine.ar(wr, 5e-5, 2000, 2, -3.dbamp);
	var jun=Junction.ar(l1+l2, ~knob.(23,1/8,8,\exp), ~knob.(13));
	var x=SinOsc.ar(200+
        (Decay.ar(
			Dust.ar([1,1.005]*~knob.(11,1/8,8,\exp)),
			1e3*jun.pow(2))*20),
		jun*~knob.(12,1/4,4,\exp), 1, jun).tanh;
	LocalOut.ar(x);
	sig = SplayAz.ar(8, x, 0.5, 1, 2, LFNoise1.kr(1/4), 0.5) * ~slider.(1);
	sig
}).reshaping_(\expanding).fadeTime_(0).play)

Ndef(\untuned_note_ascending).clear
Monitor
(
Ndef(\bus, {
	// obtain the signal of x within another NodeProxy
	var xSig = Mix.ar(Ndef(\untuned_note_ascending).ar)/8;
	// collect more signals here and e.g. combine them
	Amplitude.ar(Bus('audio', 51, 1, s).ar).poll;
	Silent.ar;
});
)

Ndef(\bus).clear

Ndef.clear

(Ndef(\test, {
	var slider=~slider.(8);
	slider.poll;
	Out.ar(0, WhiteNoise.ar(slider));
}).play;)

Ndef(\test).clear

1/~volumeNormalization

s.sampleRate = 44100

s.options.blockSize.postln;