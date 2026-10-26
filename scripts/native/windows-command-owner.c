// A native Job Object owns the suspended child before any user code can run.
// Closing this process's last job handle also stops descendants after a crash.
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static wchar_t *quote_command(int argc, wchar_t **argv) {
    size_t capacity = 1;
    for (int index = 0; index < argc; ++index) {
        const size_t length = wcslen(argv[index]);
        if (length > 32767) return NULL;
        const size_t needed = 2 * length + 3;
        if (needed > 32767 - capacity) return NULL;
        capacity += needed;
    }
    wchar_t *text = (wchar_t *)calloc(capacity, sizeof(wchar_t));
    if (!text) return NULL;
    wchar_t *out = text;
    for (int index = 0; index < argc; ++index) {
        if (index) *out++ = L' ';
        *out++ = L'"';
        const wchar_t *in = argv[index];
        while (*in) {
            size_t slashes = 0;
            while (*in == L'\\') { ++slashes; ++in; }
            size_t emit = slashes;
            if (*in == L'"' || !*in) emit *= 2;
            while (emit--) *out++ = L'\\';
            if (*in == L'"') *out++ = L'\\';
            if (*in) *out++ = *in++;
        }
        *out++ = L'"';
    }
    *out = 0;
    return text;
}
static int duplicate_standard(DWORD kind, HANDLE *handle) {
    HANDLE original = GetStdHandle(kind);
    return original && original != INVALID_HANDLE_VALUE &&
        DuplicateHandle(GetCurrentProcess(), original, GetCurrentProcess(), handle, 0, TRUE, DUPLICATE_SAME_ACCESS);
}
static int job_empty(HANDLE job) {
    JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
    if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation, &accounting, sizeof(accounting), NULL)) return -1;
    return accounting.ActiveProcesses == 0;
}
static int dispose_job(HANDLE job) {
    int empty = job_empty(job);
    if (empty == 1) return 1;
    if (!TerminateJobObject(job, 125)) return 0;
    const ULONGLONG deadline = GetTickCount64() + 5000;
    do {
        empty = job_empty(job);
        if (empty == 1) return 1;
        if (empty < 0) return 0;
        Sleep(10);
    } while (GetTickCount64() < deadline);
    return 0;
}
static int write_receipt(const wchar_t *path, DWORD code, DWORD pid, int timed_out, int cancelled, int disposed, DWORD os_error) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    char text[512];
    const int length = snprintf(text, sizeof(text), "{\"code\":%lu,\"processId\":%lu,\"timedOut\":%s,\"cancelled\":%s,\"jobDisposed\":%s,\"osError\":%lu}\n",
        code, pid, timed_out ? "true" : "false", cancelled ? "true" : "false", disposed ? "true" : "false", os_error);
    DWORD written = 0;
    const int ok = length > 0 && (size_t)length < sizeof(text) && WriteFile(file, text, (DWORD)length, &written, NULL) && written == (DWORD)length && FlushFileBuffers(file);
    CloseHandle(file);
    return ok;
}

// parent PID, timeout milliseconds, private receipt, cancellation marker,
// absolute executable, then its exact argv. No command shell is introduced.
int wmain(int argc, wchar_t **argv) {
    if (argc < 6) return 2;
    wchar_t *end = NULL;
    const unsigned long parent_pid = wcstoul(argv[1], &end, 10);
    if (!parent_pid || *end) return 2;
    const unsigned long timeout = wcstoul(argv[2], &end, 10);
    if (!timeout || timeout > 1800000 || *end) return 2;
    HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)parent_pid);
    if (!parent) return 3;
    HANDLE job = CreateJobObjectW(NULL, NULL);
    if (!job) { CloseHandle(parent); return 3; }
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        CloseHandle(job); CloseHandle(parent); return 3;
    }
    wchar_t *command = quote_command(argc - 5, argv + 5);
    if (!command) { CloseHandle(job); CloseHandle(parent); return 3; }
    HANDLE handles[3] = {NULL, NULL, NULL};
    SECURITY_ATTRIBUTES security = {sizeof(SECURITY_ATTRIBUTES), NULL, TRUE};
    handles[0] = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, NULL);
    int inherited = handles[0] != INVALID_HANDLE_VALUE && duplicate_standard(STD_OUTPUT_HANDLE, &handles[1]) && duplicate_standard(STD_ERROR_HANDLE, &handles[2]);
    STARTUPINFOEXW startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = handles[0];
    startup.StartupInfo.hStdOutput = handles[1];
    startup.StartupInfo.hStdError = handles[2];
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
    startup.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(bytes);
    const int initialized = startup.lpAttributeList && InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &bytes);
    int attributes = initialized;
    if (attributes) attributes = UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), NULL, NULL);
    PROCESS_INFORMATION child = {0};
    int launched = inherited && attributes && CreateProcessW(argv[5], command, NULL, NULL, TRUE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW, NULL, NULL, &startup.StartupInfo, &child);
    DWORD os_error = launched ? 0 : GetLastError();
    if (!launched && !os_error) os_error = ERROR_INVALID_PARAMETER;
    if (startup.lpAttributeList) {
        if (initialized) DeleteProcThreadAttributeList(startup.lpAttributeList);
        free(startup.lpAttributeList);
    }
    for (unsigned index = 0; index < 3; ++index) if (handles[index] && handles[index] != INVALID_HANDLE_VALUE) CloseHandle(handles[index]);
    free(command);
    DWORD code = 125;
    int timed_out = 0, cancelled = 0, disposed = 1;
    if (launched) {
        if (!AssignProcessToJobObject(job, child.hProcess)) {
            os_error = GetLastError();
            // The primary thread is still suspended; no descendant can exist.
            disposed = TerminateProcess(child.hProcess, 125) && WaitForSingleObject(child.hProcess, 5000) == WAIT_OBJECT_0;
        } else if (ResumeThread(child.hThread) == (DWORD)-1) {
            os_error = GetLastError();
            disposed = dispose_job(job);
        } else {
            const ULONGLONG deadline = GetTickCount64() + timeout;
            HANDLE observed[2] = {child.hProcess, parent};
            for (;;) {
                const DWORD completed = WaitForMultipleObjects(2, observed, FALSE, 20);
                if (completed == WAIT_OBJECT_0) {
                    if (!GetExitCodeProcess(child.hProcess, &code)) os_error = GetLastError();
                    break;
                }
                if (completed == WAIT_OBJECT_0 + 1) { cancelled = 1; break; }
                if (completed != WAIT_TIMEOUT) { os_error = GetLastError(); break; }
                if (GetFileAttributesW(argv[4]) != INVALID_FILE_ATTRIBUTES) { cancelled = 1; break; }
                const DWORD marker_error = GetLastError();
                if (marker_error != ERROR_FILE_NOT_FOUND && marker_error != ERROR_PATH_NOT_FOUND) { os_error = marker_error; break; }
                if (GetTickCount64() >= deadline) { timed_out = 1; code = 124; break; }
            }
            disposed = dispose_job(job);
        }
        CloseHandle(child.hThread);
        CloseHandle(child.hProcess);
    }
    CloseHandle(job);
    CloseHandle(parent);
    const int recorded = write_receipt(argv[3], code, child.dwProcessId, timed_out, cancelled, disposed, os_error);
    if (!recorded || !disposed || os_error) return 1;
    return 0;
}
