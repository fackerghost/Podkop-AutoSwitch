# Inputs: current, failures, threshold, auto, now, last_switch, cooldown,
# healthy, candidate. The policy does not perform I/O.
if .healthy then {action:"keep", failures:0}
elif .failures + 1 < .threshold then {action:"wait", failures:(.failures+1)}
elif .auto != true then {action:"disabled", failures:.threshold}
elif .now - .last_switch < .cooldown then {action:"cooldown", failures:.threshold}
elif .candidate == null or .candidate == .current then {action:"scan", failures:.threshold}
else {action:"switch", target:.candidate, failures:.threshold}
end
