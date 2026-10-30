#include "MacOSAppLifecycle.h"

#import <AppKit/AppKit.h>

#include <libproc.h>
#include <sys/proc.h>

#ifndef SZOMB
#define SZOMB 5
#endif

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "MaaUtils/Logger.h"

MAA_CTRL_UNIT_NS_BEGIN

namespace
{
struct ProcessIdentity
{
    pid_t pid = 0;
    uint64_t start_sec = 0;
    uint64_t start_usec = 0;
    uint32_t status = 0;
    uint32_t flags = 0;
    uint32_t ppid = 0;
    std::string comm;
};

struct ProcessQueryResult
{
    ProcessIdentity identity;
    int ret = 0;
    int error = 0;
};

struct PendingProcess
{
    ProcessIdentity expected;
    ProcessQueryResult observed;
};

ProcessQueryResult query_process_identity(pid_t pid)
{
    proc_bsdinfo info { };
    errno = 0;
    const int ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    const int error = errno;
    return {
        { pid,
          info.pbi_start_tvsec,
          info.pbi_start_tvusec,
          info.pbi_status,
          info.pbi_flags,
          info.pbi_ppid,
          std::string(info.pbi_comm, std::find(info.pbi_comm, info.pbi_comm + sizeof(info.pbi_comm), '\0')) },
        ret,
        error
    };
}

const char* process_exit_reason(const ProcessIdentity& expected, const ProcessQueryResult& observed)
{
    if (observed.ret <= 0) {
        return "proc_pidinfo failed";
    }
    if (observed.ret != sizeof(proc_bsdinfo)) {
        return "proc_pidinfo returned an unexpected size";
    }
    if (observed.identity.status == SZOMB) {
        return "process is a zombie";
    }
    if (observed.identity.start_sec != expected.start_sec || observed.identity.start_usec != expected.start_usec) {
        return "process start time changed";
    }
    return nullptr;
}

bool is_process_alive(PendingProcess& process)
{
    process.observed = query_process_identity(process.expected.pid);
    const char* reason = process_exit_reason(process.expected, process.observed);
    if (reason) {
        LogInfo << "Application process exited" << VAR(process.expected.pid) << VAR(reason) << VAR(process.observed.ret)
                << VAR(process.observed.error);
        return false;
    }
    return true;
}

NSURL* find_application(NSString* target, const std::string& search_path)
{
    if ([target hasPrefix:@"/"]) {
        return [NSURL fileURLWithPath:target];
    }

    NSString* directory = [[NSString stringWithUTF8String:search_path.c_str()] stringByExpandingTildeInPath];
    NSDirectoryEnumerator<NSURL*>* enumerator = [[NSFileManager defaultManager]
                   enumeratorAtURL:[NSURL fileURLWithPath:directory]
        includingPropertiesForKeys:nil
                           options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                      errorHandler:nil];
    for (NSURL* candidate in enumerator) {
        if (![candidate.pathExtension.lowercaseString isEqualToString:@"app"]) {
            continue;
        }
        if ([[NSBundle bundleWithURL:candidate].bundleIdentifier isEqualToString:target]) {
            return candidate;
        }
    }
    return [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:target];
}
}

namespace MacOSAppLifecycle
{
bool start_app(const std::string& intent, const std::string& search_path)
{
    LogFunc << VAR(intent) << VAR(search_path);

    @autoreleasepool {
        NSString* target = [NSString stringWithUTF8String:intent.c_str()];
        if (target.length == 0) {
            LogError << "Invalid application intent" << VAR(intent);
            return false;
        }

        NSURL* url = find_application(target, search_path);
        if (!url || ![NSBundle bundleWithURL:url].bundleIdentifier) {
            LogError << "Application bundle not found" << VAR(intent) << VAR(search_path);
            return false;
        }

        struct LaunchResult
        {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            bool started = false;
            std::string error;

            ~LaunchResult() { dispatch_release(semaphore); }
        };
        // The completion handler may outlive this call on the main thread or after a timeout.
        const auto result = std::make_shared<LaunchResult>();
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                              configuration:[NSWorkspaceOpenConfiguration configuration]
                                          completionHandler:^(NSRunningApplication* app, NSError* error) {
                                              result->started = app != nil;
                                              if (error) {
                                                  result->error = error.localizedDescription.UTF8String;
                                              }
                                              if (!result->started) {
                                                  LogError << "Application launch failed" << VAR(result->error);
                                              }
                                              dispatch_semaphore_signal(result->semaphore);
                                          }];
        if ([NSThread isMainThread]) {
            LogWarn << "Skipping launch completion wait on the main thread. Success only indicates the launch request was sent."
                    << VAR(intent);
            return true;
        }
        if (dispatch_semaphore_wait(result->semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) != 0) {
            LogError << "Application launch timed out" << VAR(intent);
            return false;
        }
        return result->started;
    }
}

bool stop_app(const std::string& intent)
{
    LogFunc << VAR(intent);

    @autoreleasepool {
        NSString* bundle_id = [NSString stringWithUTF8String:intent.c_str()];
        if (intent.starts_with("/")) {
            bundle_id = [NSBundle bundleWithPath:bundle_id].bundleIdentifier;
        }
        if (bundle_id.length == 0) {
            LogError << "Invalid application bundle identifier" << VAR(intent);
            return false;
        }
        NSArray<NSRunningApplication*>* apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle_id];
        if (apps.count == 0) {
            LogInfo << "Application is not running" << VAR(intent);
            return true;
        }

        bool stopped = true;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        std::vector<PendingProcess> pending;
        for (NSRunningApplication* app in apps) {
            const pid_t pid = app.processIdentifier;
            const auto snapshot = query_process_identity(pid);
            const auto& identity = snapshot.identity;
            LogDebug << "Application process snapshot" << VAR(pid) << VAR(identity.ppid) << VAR(identity.comm) << VAR(identity.status)
                     << VAR(identity.start_sec) << VAR(identity.start_usec) << VAR(snapshot.ret) << VAR(snapshot.error);
            if (snapshot.ret <= 0 && snapshot.error != ESRCH && snapshot.error != 0) {
                LogError << "Failed to query application process" << VAR(pid) << VAR(snapshot.ret) << VAR(snapshot.error);
                stopped = false;
                continue;
            }
            if (const char* reason = process_exit_reason(identity, snapshot)) {
                LogInfo << "Application already exited" << VAR(pid) << VAR(reason) << VAR(snapshot.ret) << VAR(snapshot.error);
                continue;
            }
            if (![app terminate]) {
                LogError << "Failed to send quit request" << VAR(pid);
                stopped = false;
                continue;
            }

            pending.push_back({ identity, snapshot });
        }

        while (!pending.empty()) {
            std::erase_if(pending, [](PendingProcess& process) { return !is_process_alive(process); });
            if (pending.empty()) {
                break;
            }
            if (std::chrono::steady_clock::now() >= deadline) {
                for (const auto& process : pending) {
                    const auto& expected = process.expected;
                    const auto& observed = process.observed.identity;
                    const pid_t pid = expected.pid;
                    LogError << "Application did not quit after the quit request" << VAR(pid) << VAR(process.observed.ret)
                             << VAR(process.observed.error) << VAR(observed.status) << VAR(observed.flags) << VAR(observed.ppid)
                             << VAR(observed.comm) << VAR(expected.start_sec) << VAR(expected.start_usec) << VAR(observed.start_sec)
                             << VAR(observed.start_usec);
                }
                stopped = false;
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        return stopped;
    }
}
}

MAA_CTRL_UNIT_NS_END
