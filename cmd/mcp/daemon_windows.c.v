module main

// The Windows side of starting the daemon (daemon.v). Windows has no setsid() and no
// fork, and a running .exe can't be replaced: so the server starts a copy of its
// binary, beside the daemon's socket, as a process of its own with no console and
// none of its handles, and the daemon writes its output to its log itself.

// DaemonStartupInfo is Windows' STARTUPINFOW.
struct DaemonStartupInfo {
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

// DaemonProcessInfo is Windows' PROCESS_INFORMATION.
struct DaemonProcessInfo {
mut:
	h_process     voidptr
	h_thread      voidptr
	dw_process_id u32
	dw_thread_id  u32
}

// no console, a process group of its own, and out of the client's job, which may
// end every process in it when the client ends this server
const detached_process = u32(0x00000008)
const create_new_process_group = u32(0x00000200)
const create_breakaway_from_job = u32(0x01000000)
// the error CreateProcessW gives when the job doesn't let a process leave it
const error_access_denied = u32(5)

// start_detached runs `exe` with `args` as a process of its own: no console, no
// handle of this one's (a copy of the client's stdin kept open would keep this
// server from seeing its client go), and, when the job it is in allows it, out of
// that job.
fn start_detached(exe string, args []string) ! {
	mut words := [win_quote(exe)]
	for a in args {
		words << win_quote(a)
	}
	line := words.join(' ')
	mut flags := detached_process | create_new_process_group | create_breakaway_from_job
	for {
		si := DaemonStartupInfo{
			cb: sizeof(DaemonStartupInfo)
		}
		pi := DaemonProcessInfo{}
		if C.CreateProcessW(exe.to_wide(), line.to_wide(), 0, 0, false, flags, 0, 0,
			voidptr(&si), voidptr(&pi))
		{
			C.CloseHandle(pi.h_thread)
			C.CloseHandle(pi.h_process)
			return
		}
		code := C.GetLastError()
		if code == error_access_denied && flags & create_breakaway_from_job != 0 {
			// a job that keeps its processes: the daemon stays in it
			flags &= ~create_breakaway_from_job
			continue
		}
		return error('CreateProcessW failed with code ${code}')
	}
}

// detach_windows sends the daemon's output to `log`: started with no console, it has
// no stdout or stderr, and V writes both through the C runtime's streams.
fn detach_windows(log string) {
	C._wfreopen(log.to_wide(), 'a'.to_wide(), C.stdout)
	C._wfreopen(log.to_wide(), 'a'.to_wide(), C.stderr)
}
