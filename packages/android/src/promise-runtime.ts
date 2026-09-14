const ANDROID_PROMISE_RUNTIME = `
if (window.__craftRejectPendingPromises) {
    window.__craftRejectPendingPromises('Android bridge reinitialized');
}
if (window.__craftRejectPermissionRequests) {
    window.__craftRejectPermissionRequests('Android bridge reinitialized');
}
window.__craftPromiseRuntimeClosed = false;
window.__craftPendingPromises = Object.create(null);
window.__craftPromise = function(channel, resolveName, rejectName, invoke, timeoutMs, timeoutError) {
    if (window.__craftPromiseRuntimeClosed) {
        return Promise.reject(new Error('Android bridge is closed'));
    }
    if (window.__craftPendingPromises[channel]) {
        return Promise.reject(new Error('A '.concat(channel, ' request is already in progress')));
    }

    return new Promise(function(resolve, reject) {
        var entry = {settled: false, timer: null, settle: null};
        var resolveCallback;
        var rejectCallback;

        entry.settle = function(succeeded, value) {
            if (entry.settled || window.__craftPendingPromises[channel] !== entry) return;
            entry.settled = true;
            if (entry.timer !== null) clearTimeout(entry.timer);
            if (window[resolveName] === resolveCallback) window[resolveName] = null;
            if (window[rejectName] === rejectCallback) window[rejectName] = null;
            delete window.__craftPendingPromises[channel];
            if (succeeded) resolve(value);
            else reject(value);
        };

        resolveCallback = function(value) {
            entry.settle(true, value);
        };
        rejectCallback = function(error) {
            entry.settle(false, error);
        };
        window[resolveName] = resolveCallback;
        window[rejectName] = rejectCallback;
        window.__craftPendingPromises[channel] = entry;

        if (timeoutMs > 0) {
            entry.timer = setTimeout(function() {
                entry.settle(false, timeoutError || new Error(channel.concat(' request timed out')));
            }, timeoutMs);
        }

        try {
            invoke();
        }
        catch (error) {
            entry.settle(false, error);
        }
    });
};

window.__craftRejectPendingPromises = function(message) {
    window.__craftPromiseRuntimeClosed = true;
    Object.keys(window.__craftPendingPromises).forEach(function(channel) {
        var entry = window.__craftPendingPromises[channel];
        if (entry) entry.settle(false, new Error(message || 'Android bridge closed'));
    });
};
`

export function renderAndroidPromiseRuntime(indent = ''): string {
  return ANDROID_PROMISE_RUNTIME
    .trim()
    .split('\n')
    .map(line => `${indent}${line}`)
    .join('\n')
}

export { ANDROID_PROMISE_RUNTIME }
