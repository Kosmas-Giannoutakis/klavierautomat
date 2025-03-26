DDWSnippets.load(\SCTweets_mod1)

//Tweet by Batuhan Bozkurt (earslap)
//https://earslap.com/

(Ndef(\untuned_note_ascending, {
	var in=SoundIn.ar(0);
    var fb=LocalIn.ar(4);
    var wr=Write.ar(fb);
	var l1=FDLine.ar(wr, in.mdAmp(7e-3,3e-5,\exp,1.2), 200, 0.2);
	var l2=FDLine.ar(wr, fb.mdFlat(7e-5,9e-2,\exp,0.9), 80, 1.2);
	var l3=FDLine.ar(wr, in.mdPitch(3e-2,5e-5,\exp,0.8), 2000, 0.5);
	var jun=Junction.ar(l1+l2+l3, 1, ~knob.(13));
    var x=SinOsc.ar(50+
        (Decay.ar(
			Dust.ar([1,1.005,1.01,1.015]*~knob.(11,1/8,8,\exp)),
			1e3*jun.pow(2))*20),
		jun*~knob.(12,1/4,4,\exp), 1, jun).tanh;
	// Amplitude.ar(in[0]).poll;
	LocalOut.ar(x);
	SplayAz.ar(8, x, 0.2, 1, 8, LFNoise2.kr(1/4), 0.5) * ~slider.(1) * ~volumeNormalization;
}).reshaping_(\expanding).fadeTime_(0).play)

Ndef(\untuned_note_ascending).clear

Ndef.clear

(Ndef(\test, {
	var slider=~slider.(8);
	slider.poll;
	WhiteNoise.ar(slider)
}).play;)

Ndef(\test).clear

1/~volumeNormalization