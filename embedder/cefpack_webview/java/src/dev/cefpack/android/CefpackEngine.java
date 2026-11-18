// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package dev.cefpack.android;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import android.util.Log;

import org.jni_zero.JNINamespace;
import org.jni_zero.NativeMethods;

import org.chromium.base.ApplicationStatus;
import org.chromium.base.CommandLine;
import org.chromium.base.ContextUtils;
import org.chromium.base.PathUtils;
import org.chromium.base.ThreadUtils;
import org.chromium.base.library_loader.LibraryLoader;
import org.chromium.base.library_loader.LibraryProcessType;
import org.chromium.content_public.browser.BrowserStartupController;
import org.chromium.content_public.browser.DeviceUtils;
import org.chromium.net.NetworkChangeNotifier;
import org.chromium.ui.base.ActivityWindowAndroid;
import org.chromium.ui.base.IntentRequestTracker;
import org.chromium.ui.base.ResourceBundle;
import org.chromium.ui.base.WindowAndroid;

import java.util.Map;
import java.util.WeakHashMap;

/**
 * Process-wide initializer and controller for the Cefpack Chromium content embedder.
 *
 * <p>Built directly on {@code //content/public/android} with zero desktop Chrome UI, zero Google
 * Play Services, zero JavaScript execution, and live SOCKS5 proxy routing.
 */
@JNINamespace("cefpack")
public final class CefpackEngine {
    public static final String LOG_TAG = "Cefpack";
    private static final String PRIVATE_DATA_DIR_SUFFIX = "cefpack";

    private static volatile boolean sProcessInitialized;
    private static volatile boolean sBrowserStarted;
    private static volatile String sPendingProxyServer = "socks5://127.0.0.1:1";

    private static final Map<Activity, ActivityWindowAndroid> sActivityWindows =
            new WeakHashMap<>();

    private CefpackEngine() {}

    /**
     * Initializes Chromium process-global context and library loader process type. Safe to call in
     * both the main browser process and {@code :sandboxed_process*} / {@code :privileged_process*}
     * child service processes from {@code Application.attachBaseContext} or {@code onCreate}.
     */
    public static synchronized void initProcess(Context context) {
        if (sProcessInitialized) {
            return;
        }
        Context appContext =
                context.getApplicationContext() != null ? context.getApplicationContext() : context;
        ContextUtils.initApplicationContext(appContext);
        ResourceBundle.setNoAvailableLocalePaks();

        String processName = ContextUtils.getProcessName();
        boolean isBrowserProcess = processName == null || !processName.contains(":");
        LibraryLoader.getInstance()
                .setLibraryProcessType(
                        isBrowserProcess
                                ? LibraryProcessType.PROCESS_BROWSER
                                : LibraryProcessType.PROCESS_CHILD);
        if (isBrowserProcess) {
            PathUtils.setPrivateDataDirectorySuffix(PRIVATE_DATA_DIR_SUFFIX);
            if (appContext instanceof Application) {
                ApplicationStatus.initialize((Application) appContext);
            }
        }
        sProcessInitialized = true;
    }

    /**
     * Synchronously loads {@code libcefpack_content.so} and starts the Chromium browser main loop
     * on the Android UI thread.
     */
    public static synchronized boolean initialize(Context context) {
        ThreadUtils.assertOnUiThread();
        if (sBrowserStarted) {
            return true;
        }
        try {
            Context appContext =
                    context.getApplicationContext() != null
                            ? context.getApplicationContext()
                            : context;
            initProcess(appContext);

            if (!CommandLine.isInitialized()) {
                CommandLine.init(
                        new String[] {
                            "cefpack",
                            "--disable-features=PartitionAllocMemoryTagging,AutofillServerCommunication,OptimizationHints,Translate,MediaRouter,WebRtcHideLocalIpsWithMdns,HttpsUpgrades,HttpsFirstBalancedModeAutoEnable",
                            "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1",
                            "--dns-prefetch-disable",
                            "--no-pings",
                            "--disable-background-networking",
                            "--js-flags=--jitless,--no-expose-wasm"
                        });
            }

            DeviceUtils.updateDeviceSpecificUserAgentSwitch(appContext);
            LibraryLoader.getInstance().ensureInitialized();
            NetworkChangeNotifier.init();

            BrowserStartupController.getInstance()
                    .startBrowserProcessesSync(
                            LibraryProcessType.PROCESS_BROWSER,
                            /* singleProcess= */ false,
                            /* startGpuProcess= */ true);

            sBrowserStarted = true;
            CefpackEngineJni.get().setProxyServer(sPendingProxyServer);
            Log.i(LOG_TAG, "Initialized Cefpack content engine (proxy=" + sPendingProxyServer + ")");
            return true;
        } catch (Throwable t) {
            Log.e(LOG_TAG, "Failed to initialize Cefpack content engine", t);
            return false;
        }
    }

    public static boolean isInitialized() {
        return sBrowserStarted;
    }

    /** Updates the live SOCKS5 proxy across all active and future NetworkContexts. */
    public static void setProxyServer(String proxyServer) {
        String normalized =
                (proxyServer == null || proxyServer.trim().isEmpty())
                        ? "socks5://127.0.0.1:1"
                        : proxyServer.trim();
        sPendingProxyServer = normalized;
        if (sBrowserStarted) {
            ThreadUtils.runOnUiThread(() -> CefpackEngineJni.get().setProxyServer(normalized));
        }
    }

    /** Rotates the ephemeral off-the-record BrowserContext so new tabs get clean state. */
    public static void resetEphemeralProfile() {
        if (sBrowserStarted) {
            ThreadUtils.runOnUiThread(() -> CefpackEngineJni.get().resetEphemeralContext());
        }
    }

    /** Fast-terminates idle/spare renderer processes that hold zero active pages. */
    public static void reapUnusedRenderers() {
        if (sBrowserStarted) {
            ThreadUtils.runOnUiThread(() -> CefpackEngineJni.get().reapUnusedRenderers());
        }
    }

    static synchronized WindowAndroid obtainWindowAndroid(Context context) {
        Activity activity = ContextUtils.activityFromContext(context);
        if (activity != null) {
            ActivityWindowAndroid existing = sActivityWindows.get(activity);
            if (existing != null) {
                return existing;
            }
            IntentRequestTracker tracker = IntentRequestTracker.createFromActivity(activity);
            ActivityWindowAndroid created =
                    new ActivityWindowAndroid(
                            activity,
                            /* listenToActivityState= */ true,
                            tracker,
                            /* insetObserver= */ null,
                            /* occlusionTrackingAllowed= */ true);
            sActivityWindows.put(activity, created);
            return created;
        }
        return new WindowAndroid(context, /* trackOcclusion= */ false);
    }

    @NativeMethods
    interface Natives {
        void setProxyServer(String proxyServer);

        void resetEphemeralContext();

        void reapUnusedRenderers();
    }
}
