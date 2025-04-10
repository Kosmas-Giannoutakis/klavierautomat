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
	// var l1=FDLine.ar(wr, in.mdAmp(7e-3,3e-5,\exp,1.2), 200, 0.2);
	// var l2=FDLine.ar(wr, fb.mdFlat(7e-5,9e-2,\exp,0.9), 80, 1.2);
	// var l3=FDLine.ar(wr, in.mdPitch(3e-2,5e-5,\exp,0.8), 2000, 0.5);
	var jun=Junction.ar(l1+l2, ~knob.(23,1/8,8,\exp), ~knob.(13));
	var x=SinOsc.ar([80, 250]+
        (Decay.ar(
			Dust.ar([1,1.005]*~knob.(11,1/8,8,\exp)),
			1e3*jun.pow(2))*20),
		jun*~knob.(12,1/4,4,\exp), 1, jun).tanh;
	// Amplitude.ar(in[0]).poll;
	// Out.ar(~monitorBus, Mix.ar(x)/x.size * ~slider.(2));
	mix=Mix.ar(x)/2 *~slider.(2);
	LocalOut.ar(x);
	sig = SplayAz.ar(8, x, 0.5, 1, 2, LFNoise1.kr(1/8), 0.5) * ~slider.(1);
	// Amplitude.ar(sig).poll;
	sig ++ mix;
}).reshaping_(\expanding).fadeTime_(0).playN((0..7) ++ [51]))

Ndef(\untuned_note_ascending).clear
Monitor
(
Ndef(\bus, {
	Amplitude.ar(In.ar(51,1)).poll;
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