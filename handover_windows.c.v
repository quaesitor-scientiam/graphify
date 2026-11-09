module graphify

// HandoverStartupInfo is Windows' STARTUPINFOW, as run_waiting passes it: all zero but
// its size, so the child takes this process's console and standard streams.
struct HandoverStartupInfo {
mut:
	cb                 u32
	lp_reserved        &u16 = unsafe { nil }
	lp_desktop         &u16 = unsafe { nil }
	lp_title           &u16 = unsafe { nil }
	dw_x               u32
	dw_y               u32
	dw_x_size          u32
	dw_y_size          u32
	dw_x_count_chars   u32
	dw_y_count_chars   u32
	dw_fill_attributes u32
	dw_flags           u32
	w_show_window      u16
	cb_reserved2       u16
	lp_reserved2       &u8 = unsafe { nil }
	h_std_input        voidptr
	h_std_output       voidptr
	h_std_error        voidptr
}

// HandoverProcessInfo is Windows' PROCESS_INFORMATION.
struct HandoverProcessInfo {
mut:
	h_process     voidptr
	h_thread      voidptr
	dw_process_id u32
	dw_thread_id  u32
}

// run_waiting runs `exe` with `args` on this process's console and standard streams,
// inheriting its handles as os.system_args does, waits for it, and returns its exit
// code; none when it can't be started (a file that is no program, one an antivirus
// refuses), which os.system_args reports by exiting. The CLI's `extract` hands over to
// its extractor with it, Windows having no exec.
pub fn run_waiting(exe string, args []string) ?int {
	mut words := [win_quote(exe)]
	for a in args {
		words << win_quote(a)
	}
	line := words.join(' ')
	si := HandoverStartupInfo{
		cb: sizeof(HandoverStartupInfo)
	}
	pi := HandoverProcessInfo{}
	if !C.CreateProcessW(exe.to_wide(), line.to_wide(), 0, 0, true, 0, 0, 0, voidptr(&si),
		voidptr(&pi)) {
		return none
	}
	C.CloseHandle(pi.h_thread)
	C.WaitForSingleObject(pi.h_process, C.INFINITE)
	mut code := u32(0)
	// a process that ran and whose code can't be read failed for its caller: it may have
	// written part of its output, which a second extract here would not mend
	got := unsafe { C.GetExitCodeProcess(pi.h_process, &C.DWORD(&code)) }
	C.CloseHandle(pi.h_process)
	return if got { int(code) } else { 1 }
}
