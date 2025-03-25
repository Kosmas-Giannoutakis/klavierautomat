DDWSnippets.load(\SCTweets_mod1)

//Tweet by Batuhan Bozkurt (earslap)
//https://earslap.com/

(Ndef(\untuned_note_ascending, {
    var fb=LocalIn.ar(2).sum;
    var wr=Write.ar(fb);
	var l1=FDLine.ar(wr, fb.mdPitch(5e-4,6e-5,\exp,1.2), 2000, 2);
	var l2=FDLine.ar(wr, fb.mdFlat(2e-5,5e-2,\exp,2.2), 80, 1);
	var l3=FDLine.ar(wr, 7e-3, 200, 0.2);
	var jun=Junction.ar(l1+l2+l3, 1, ~knob.(13));
    var x=SinOsc.ar(
        (Decay.ar(
			Impulse.ar([1,1.005]*~knob.(11,1/8,8,\exp)),
			1e3*jun.pow(2))*20+40),
		jun*~knob.(12,1/4,4,\exp), 1, jun).tanh;
    LocalOut.ar(x);
    Splay.ar(x) * ~slider.(1);
}).fadeTime_(0).play)

Ndef(\untuned_note_ascending).clear

