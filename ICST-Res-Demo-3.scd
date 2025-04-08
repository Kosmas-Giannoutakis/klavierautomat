DDWSnippets.load(\SCTweets_mod1)

//Tweet by Batuhan Bozkurt (earslap)
//https://earslap.com/


(Ndef(\untuned_note_ascending, {
	var mix, sig;
	var in=SoundIn.ar([2,3,4]).sum/3;
    var fb=LocalIn.ar(3);
    var wr=Write.ar(fb);
	var l1=FDLine.ar(wr, 3e-4, 80, 0.5);
	var l2=FDLine.ar(wr, in.mdAmp(2e-5,4e-3,\exp,2.3), 2080, 1.2, -5.dbamp);
	var l3=FDLine.ar(wr, in.msPitch(8e-5, 3e-3,\exp,3.4), 890, 0.9, -3.dbamp);
	var jun=Junction.ar(l1+l2+l3, ~knob.(23,1/8,8,\exp), ~knob.(13));
	var x=SinOsc.ar(LFSaw.kr(~knob.(21,1/32,32,\exp)).exprange(~knob.(31,60,4000,\exp),~knob.(32,60,4000,\exp))+
        (Decay.ar(
			Dust.ar([1,1.005]*~knob.(11,1/32,32,\exp)),
			1e3*jun.pow(2))*(in.abs*100)),
		jun*~knob.(12,1/8,8,\exp), 1, jun).tanh;
	LocalOut.ar(x);
	sig = SplayAz.ar(8, x, 1, 1, 2, LFNoise1.kr(1/5), 0.5) * ~slider.(1);
	sig
}).reshaping_(\expanding).fadeTime_(3).play)

Ndef(\untuned_note_ascending).clear
