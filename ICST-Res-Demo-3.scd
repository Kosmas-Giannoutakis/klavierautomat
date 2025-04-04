DDWSnippets.load(\SCTweets_mod1)

//Tweet by Batuhan Bozkurt (earslap)
//https://earslap.com/


(Ndef(\untuned_note_ascending, {
	var mix, sig;
	var in=SoundIn.ar(0);
    var fb=LocalIn.ar(2);
    var wr=Write.ar(fb);
	var l1=FDLine.ar(wr, 3e-4, 80, 0.5);
	var jun=Junction.ar(l1, ~knob.(23,1/8,8,\exp), ~knob.(13));
	var x=SinOsc.ar([80,85]+
        (Decay.ar(
			Dust.ar([1,1.005]*~knob.(11,1/8,8,\exp)),
			1e3*jun.pow(2))*20),
		jun*~knob.(12,1/4,4,\exp), 1, jun).tanh;
	LocalOut.ar(x);
	sig = SplayAz.ar(8, x, 0.5, 1, 2, LFSaw.kr(1), 0.5) * ~slider.(1);
	sig
}).reshaping_(\expanding).fadeTime_(3).play)

Ndef(\untuned_note_ascending).clear
