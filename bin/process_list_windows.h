// Windows' process snapshot, for bin/update-vlang-graph.vsh (list_processes).
// The TCC that V builds the script with has no tlhelp32.h, and its kernel32 import list
// has no Process32FirstW, so for TCC this declares what the script uses of the header,
// as tlhelp32.h does, and finds the functions in kernel32.dll when they are called;
// every other compiler has the header.
#ifdef __TINYC__
#define TH32CS_SNAPPROCESS 0x00000002
typedef struct tagPROCESSENTRY32W {
	DWORD dwSize;
	DWORD cntUsage;
	DWORD th32ProcessID;
	ULONG_PTR th32DefaultHeapID;
	DWORD th32ModuleID;
	DWORD cntThreads;
	DWORD th32ParentProcessID;
	LONG pcPriClassBase;
	DWORD dwFlags;
	WCHAR szExeFile[MAX_PATH];
} PROCESSENTRY32W;
typedef HANDLE(WINAPI *gf_snapshot_fn)(DWORD, DWORD);
typedef BOOL(WINAPI *gf_process_fn)(HANDLE, PROCESSENTRY32W *);
static FARPROC gf_kernel32(const char *name) {
	return GetProcAddress(GetModuleHandleA("kernel32.dll"), name);
}
// kernel32 is loaded in every Windows process
#define CreateToolhelp32Snapshot(flags, pid) \
	((gf_snapshot_fn)gf_kernel32("CreateToolhelp32Snapshot"))(flags, pid)
#define Process32FirstW(snapshot, entry) \
	((gf_process_fn)gf_kernel32("Process32FirstW"))(snapshot, entry)
#define Process32NextW(snapshot, entry) \
	((gf_process_fn)gf_kernel32("Process32NextW"))(snapshot, entry)
#else
#include <tlhelp32.h>
#endif
