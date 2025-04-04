(
s.waitForBoot({

	var sNums = [19,23,27,31,49,53,57,61,62];
	var kNums = [[16,17,18],[20,21,22],[24,25,26],[28,29,30],[46,47,48],[50,51,52],[54,55,56],[58,59,60]];

	var knobs=8.collect({3.collect({Bus.control(s, 1)})});
	~sliders=9.collect({Bus.control(s, 1)});

	MIDIIn.connectAll;

	MIDIdef.cc(("masterVolume").asSymbol, { |val|
		var normalizedValue = val/127; // Normalize to 0-1
		var curvedValue = normalizedValue ** 4; // Apply a power of 4 curve
		var dbValue = [-80, -12, \exp].asSpec.map(curvedValue); // Map to dB using asSpec
		s.volume = dbValue;
	}, 62).permanent_(true); // Use correct CC number 62

	sNums.do { |ccnum, index|
		MIDIdef.cc(("slider" ++ ccnum).asSymbol, { |val|
			~sliders[index].set(val/127);
		}, ccnum).permanent_(true);
	};

	kNums.do { |item, index1|
		item.do { |ccnum, index2|
			MIDIdef.cc(("knob" ++ ccnum).asSymbol, { |val|
				knobs[index1][index2].set(val/127);
			}, ccnum).permanent_(true);
		}

	};

	MIDIdef.noteOn(\panicButton, { |val, num|
		// Send panic message directly with no additional logic
		~oscClient.sendMsg("/panic");
		"PANIC message sent to %".format(~klavierautomatIP).postln;
	}, 27).permanent_(true);

	~slider = {
		arg num;
		~sliders[num-1].kr.lag**4
	};

	~sliderValue = {
		arg num;
		var slider=~sliders[num-1].getSynchronous;
		[1e-6,1,\lin].asSpec.map(slider)**4;
	};

	~knob = {
		arg num, low=1e-8, high=1, curve=\lin;
		var col=(num/10).asInteger;
		var row=num%10;
		var knob=knobs[col-1][row-1].kr.lag;
		[low,high,curve].asSpec.map(knob)
	};

	~knobValue = {
		arg num, low=1e-8, high=1, curve=\lin;
		var col = (num/10).asInteger;
		var row = num%10;
		var knobRaw = knobs[col-1][row-1].getSynchronous;
		[low, high, curve].asSpec.map(knobRaw);
	};
})
)