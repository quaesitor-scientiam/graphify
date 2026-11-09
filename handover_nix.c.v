module graphify

// run_waiting is Windows' (handover_windows.c.v): elsewhere the CLI hands its
// extract over with exec, so there is none to run.
pub fn run_waiting(exe string, args []string) ?int {
	return none
}
