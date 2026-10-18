package core.ds;
// Generated from src/core/ds/ring.ml. Do not edit.
class RingState<T0> {
	public final values:Array<T0>;
	public var index:ml2hx.rt.Int63;
	public var numFilled:ml2hx.rt.Int63;
	public function new(values:Array<T0>, index:ml2hx.rt.Int63, numFilled:ml2hx.rt.Int63) {
		this.values = values;
		this.index = index;
		this.numFilled = numFilled;
	}
}
class RingModule {
	public static function create<T1>():(ml2hx.rt.Int63 -> (T1 -> RingState<T1>)) {
		return function(_ml1:ml2hx.rt.Int63):(T1 -> RingState<T1>) {
			return function(_ml3:T1):RingState<T1> {
				var _ml0 = _ml1;
				var _ml2 = _ml3;
				var _ml4 = _ml0;
				var _ml5 = _ml2;
				return (function() {
					var _ml8 = ml2hx.rt.Int63.parse("0");
					var _ml7 = ml2hx.rt.Int63.parse("0");
					var _ml6 = (function() {
						var _ml10 = _ml5;
						var _ml9 = _ml4;
						return ml2hx.rt.Runtime.arrayMake(_ml9, _ml10);
					})();
					return new RingState<T1>(_ml6, _ml7, _ml8);
				})();
			};
		};
	}
	public static function push<T2>():(RingState<T2> -> (T2 -> ml2hx.rt.Unit)) {
		return function(_ml12:RingState<T2>):(T2 -> ml2hx.rt.Unit) {
			return function(_ml14:T2):ml2hx.rt.Unit {
				var _ml11 = _ml12;
				var _ml13 = _ml14;
				var _ml15 = _ml11;
				var _ml16 = _ml13;
				(function() {
					var _ml19 = _ml16;
					var _ml18 = _ml15.index;
					var _ml17 = _ml15.values;
					return ml2hx.rt.Runtime.arraySet(_ml17, _ml18, _ml19);
				})();
				(function() {
					var _ml21 = (function() {
						var _ml23 = ml2hx.rt.Int63.parse("1");
						var _ml22 = _ml15.numFilled;
						return ml2hx.rt.Int63.add(_ml22, _ml23);
					})();
					var _ml20 = _ml15;
					return (function() {
						_ml20.numFilled = _ml21;
						return ml2hx.rt.Unit.value;
					})();
				})();
				if ((function() {
					var _ml25 = (function() {
						var _ml27 = ml2hx.rt.Int63.parse("1");
						var _ml26 = (function() {
							var _ml28 = _ml15.values;
							return ml2hx.rt.Int63.ofInt(_ml28.length);
						})();
						return ml2hx.rt.Int63.sub(_ml26, _ml27);
					})();
					var _ml24 = _ml15.index;
					return ml2hx.rt.Int63.eq(_ml24, _ml25);
				})()) {
					return (function() {
						var _ml30 = ml2hx.rt.Int63.parse("0");
						var _ml29 = _ml15;
						return (function() {
							_ml29.index = _ml30;
							return ml2hx.rt.Unit.value;
						})();
					})();
				}
				else {
					return (function() {
						var _ml32 = (function() {
							var _ml34 = ml2hx.rt.Int63.parse("1");
							var _ml33 = _ml15.index;
							return ml2hx.rt.Int63.add(_ml33, _ml34);
						})();
						var _ml31 = _ml15;
						return (function() {
							_ml31.index = _ml32;
							return ml2hx.rt.Unit.value;
						})();
					})();
				}
			};
		};
	}
	public static function iter<T3, T4>():(RingState<T3> -> ((T3 -> T4) -> ml2hx.rt.Unit)) {
		return function(_ml36:RingState<T3>):((T3 -> T4) -> ml2hx.rt.Unit) {
			return function(_ml38:(T3 -> T4)):ml2hx.rt.Unit {
				var _ml35 = _ml36;
				var _ml37 = _ml38;
				var _ml39 = _ml35;
				var _ml40 = _ml37;
				var _ml41:ml2hx.rt.Int63 = (function() {
					var _ml42 = _ml39.values;
					return ml2hx.rt.Int63.ofInt(_ml42.length);
				})();
				return (function() {
					var _ml44 = ml2hx.rt.Int63.parse("0");
					var _ml45 = (function() {
						var _ml47 = ml2hx.rt.Int63.parse("1");
						var _ml46 = _ml41;
						return ml2hx.rt.Int63.sub(_ml46, _ml47);
					})();
					var _ml43 = _ml44;
					while (ml2hx.rt.Int63.compare(_ml43, _ml45) <= 0) {
						(function() {
							var _ml48:ml2hx.rt.Int63 = (function() {
								var _ml50 = _ml43;
								var _ml49 = _ml39.index;
								return ml2hx.rt.Int63.add(_ml49, _ml50);
							})();
							var _ml51:ml2hx.rt.Int63 = (function() {
								if ((function() {
									var _ml53 = _ml41;
									var _ml52 = _ml48;
									return (ml2hx.rt.Int63.compare(_ml52, _ml53) >= 0);
								})()) {
									return (function() {
										var _ml55 = _ml41;
										var _ml54 = _ml48;
										return ml2hx.rt.Int63.sub(_ml54, _ml55);
									})();
								}
								else {
									return _ml48;
								}
							})();
							return (function() {
								var _ml56 = (function() {
									var _ml59 = _ml51;
									var _ml58 = _ml39.values;
									return ml2hx.rt.Runtime.arrayGet(_ml58, _ml59);
								})();
								var _ml57 = _ml40;
								return (_ml57)(_ml56);
							})();
						})();
						if (ml2hx.rt.Int63.eq(_ml43, _ml45)) break;
						_ml43 = ml2hx.rt.Int63.add(_ml43, ml2hx.rt.Int63.ofInt(1));
					}
					return ml2hx.rt.Unit.value;
				})();
			};
		};
	}
	public static function fold<T5, T6>():(RingState<T5> -> (T6 -> ((T6 -> (T5 -> T6)) -> T6))) {
		return function(_ml61:RingState<T5>):(T6 -> ((T6 -> (T5 -> T6)) -> T6)) {
			return function(_ml63:T6):((T6 -> (T5 -> T6)) -> T6) {
				return function(_ml65:(T6 -> (T5 -> T6))):T6 {
					var _ml60 = _ml61;
					var _ml62 = _ml63;
					var _ml64 = _ml65;
					var _ml66 = _ml60;
					var _ml67 = _ml62;
					var _ml68 = _ml64;
					var _ml69:ml2hx.rt.Int63 = (function() {
						var _ml70 = _ml66.values;
						return ml2hx.rt.Int63.ofInt(_ml70.length);
					})();
					var _ml71:(ml2hx.rt.Int63 -> (T6 -> T6)) = null;
					_ml71 = function(_ml73:ml2hx.rt.Int63):(T6 -> T6) {
						return function(_ml75:T6):T6 {
							var _ml72 = _ml73;
							var _ml74 = _ml75;
							while (true) {
								var _ml76 = _ml72;
								var _ml77 = _ml74;
								if ((function() {
									var _ml79 = _ml69;
									var _ml78 = _ml76;
									return ml2hx.rt.Int63.eq(_ml78, _ml79);
								})()) {
									return _ml77;
								}
								else {
									var _ml80:ml2hx.rt.Int63 = (function() {
										var _ml82 = _ml76;
										var _ml81 = _ml66.index;
										return ml2hx.rt.Int63.add(_ml81, _ml82);
									})();
									var _ml83:ml2hx.rt.Int63 = (function() {
										if ((function() {
											var _ml85 = _ml69;
											var _ml84 = _ml80;
											return (ml2hx.rt.Int63.compare(_ml84, _ml85) >= 0);
										})()) {
											return (function() {
												var _ml87 = _ml69;
												var _ml86 = _ml80;
												return ml2hx.rt.Int63.sub(_ml86, _ml87);
											})();
										}
										else {
											return _ml80;
										}
									})();
									var _ml89 = (function() {
										var _ml93 = (function() {
											var _ml96 = _ml83;
											var _ml95 = _ml66.values;
											return ml2hx.rt.Runtime.arrayGet(_ml95, _ml96);
										})();
										var _ml92 = _ml77;
										var _ml94 = _ml68;
										return ((_ml94)(_ml92))(_ml93);
									})();
									var _ml88 = (function() {
										var _ml91 = ml2hx.rt.Int63.parse("1");
										var _ml90 = _ml76;
										return ml2hx.rt.Int63.add(_ml90, _ml91);
									})();
									_ml72 = _ml88;
									_ml74 = _ml89;
									continue;
								}
							}
						};
					};
					return (function() {
						var _ml98 = _ml67;
						var _ml97 = ml2hx.rt.Int63.parse("0");
						var _ml99 = _ml71;
						return ((_ml99)(_ml97))(_ml98);
					})();
				};
			};
		};
	}
	public static function find<T7>():(RingState<T7> -> ((T7 -> Bool) -> T7)) {
		return function(_ml101:RingState<T7>):((T7 -> Bool) -> T7) {
			return function(_ml103:(T7 -> Bool)):T7 {
				var _ml100 = _ml101;
				var _ml102 = _ml103;
				var _ml104 = _ml100;
				var _ml105 = _ml102;
				var _ml106:ml2hx.rt.Int63 = (function() {
					var _ml107 = _ml104.values;
					return ml2hx.rt.Int63.ofInt(_ml107.length);
				})();
				var _ml108:(ml2hx.rt.Int63 -> T7) = null;
				_ml108 = function(_ml110:ml2hx.rt.Int63):T7 {
					var _ml109 = _ml110;
					while (true) {
						var _ml111 = _ml109;
						if ((function() {
							var _ml113 = _ml106;
							var _ml112 = _ml111;
							return ml2hx.rt.Int63.eq(_ml112, _ml113);
						})()) {
							return (function() {
								var _ml114 = core.ds.NotFound.raise();
								return (function():T7 {
									throw _ml114;
								})();
							})();
						}
						else {
							var _ml115:T7 = (function() {
								var _ml117 = _ml111;
								var _ml116 = _ml104.values;
								return ml2hx.rt.Runtime.arrayGet(_ml116, _ml117);
							})();
							if ((function() {
								var _ml118 = _ml115;
								var _ml119 = _ml105;
								return (_ml119)(_ml118);
							})()) {
								return _ml115;
							}
							else {
								var _ml120 = (function() {
									var _ml122 = ml2hx.rt.Int63.parse("1");
									var _ml121 = _ml111;
									return ml2hx.rt.Int63.add(_ml121, _ml122);
								})();
								_ml109 = _ml120;
								continue;
							}
						}
					}
				};
				return (function() {
					var _ml123 = ml2hx.rt.Int63.parse("0");
					var _ml124 = _ml108;
					return (_ml124)(_ml123);
				})();
			};
		};
	}
	public static function isFilled<T8>():(RingState<T8> -> Bool) {
		return function(_ml126:RingState<T8>):Bool {
			var _ml125 = _ml126;
			var _ml127 = _ml125;
			return (function() {
				var _ml129 = (function() {
					var _ml130 = _ml127.values;
					return ml2hx.rt.Int63.ofInt(_ml130.length);
				})();
				var _ml128 = _ml127.numFilled;
				return (ml2hx.rt.Int63.compare(_ml128, _ml129) >= 0);
			})();
		};
	}
	public static function resetFilled<T9>():(RingState<T9> -> ml2hx.rt.Unit) {
		return function(_ml132:RingState<T9>):ml2hx.rt.Unit {
			var _ml131 = _ml132;
			var _ml133 = _ml131;
			return (function() {
				var _ml135 = ml2hx.rt.Int63.parse("0");
				var _ml134 = _ml133;
				return (function() {
					_ml134.numFilled = _ml135;
					return ml2hx.rt.Unit.value;
				})();
			})();
		};
	}
}
