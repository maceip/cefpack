// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package dev.cefpack.android;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.util.SparseArray;
import android.view.ActionMode;
import android.view.InputDevice;
import android.view.Menu;
import android.view.MenuItem;
import android.view.MotionEvent;
import android.view.PixelCopy;
import android.view.SurfaceView;
import android.view.View;
import android.widget.FrameLayout;

import org.jni_zero.CalledByNative;
import org.jni_zero.JNINamespace;
import org.jni_zero.NativeMethods;

import org.chromium.base.ThreadUtils;
import org.chromium.components.embedder_support.view.ContentView;
import org.chromium.components.embedder_support.view.ContentViewRenderView;
import org.chromium.content_public.browser.ActionModeCallback;
import org.chromium.content_public.browser.ActionModeCallbackHelper;
import org.chromium.content_public.browser.LoadUrlParams;
import org.chromium.content_public.browser.MediaSession;
import org.chromium.content_public.browser.NavigationController;
import org.chromium.content_public.browser.SelectionMenuItem;
import org.chromium.content_public.browser.SelectionPopupController;
import org.chromium.content_public.browser.Visibility;
import org.chromium.content_public.browser.WebContents;
import org.chromium.ui.base.WindowAndroid;
import org.chromium.url.GURL;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Per-tab browser session backed by a Chromium {@link WebContents}, {@link ContentViewRenderView},
 * and {@link ContentView}.
 */
@JNINamespace("cefpack")
public final class CefpackSession {
    public static final class NavigationEntry {
        private final String mUrl;
        private final String mTitle;
        private final boolean mCurrent;

        public NavigationEntry(String url, String title, boolean current) {
            mUrl = url != null ? url : "";
            mTitle = title != null ? title : "";
            mCurrent = current;
        }

        public String getUrl() {
            return mUrl;
        }

        public String getTitle() {
            return mTitle;
        }

        public boolean isCurrent() {
            return mCurrent;
        }
    }

    public interface SessionCallback {
        default void onLoadStart(String url) {}

        default void onLoadEnd(int httpStatusCode, boolean isPrimaryMainFrame, String url) {}

        default void onUrlChanged(String url) {}

        default void onTitleChanged(String title) {}

        default void onLoadingProgress(int progress) {}

        default void onLoadingStateChanged(
                boolean isLoading, boolean canGoBack, boolean canGoForward) {}

        default void onLoadError(int errorCode, String errorText, String failedUrl) {}

        default void onDocumentAvailable() {}

        default void onFullscreenChanged(boolean isFullscreen) {}

        default void onAudioStateChanged(boolean isPlaying) {}

        default void onMediaAccessChange(boolean hasVideo, boolean hasAudio) {}
    }

    public interface RequestInterceptor {
        boolean shouldBlockRequest(
                String url,
                String method,
                boolean isMainFrame,
                String resourceType,
                String topLevelUrl);
    }

    public interface PopupHandler {
        boolean onPopupRequested(String targetUrl, boolean userGesture);
    }

    public interface ColorCallback {
        void onColorSelected(int argbColor);

        void onDismissed();
    }

    public interface ColorPickerHandler {
        boolean onShowColorPicker(int initialColor, ColorCallback callback);
    }

    public interface ContextMenuListener {
        void onContextMenu(String linkUrl, String srcUrl, String selectionText);
    }

    public interface DevToolsResultCallback {
        void onResult(boolean success, String resultJson);
    }

    public interface DevToolsEventListener {
        void onEvent(String method, String paramsJson);
    }

    public interface BitmapCallback {
        void onBitmapCaptured(Bitmap bitmap);
    }

    private final Context mContext;
    private WindowAndroid mWindowAndroid;
    private final FrameLayout mSurfaceContainer;
    private ContentViewRenderView mRenderView;
    private ContentView mContentView;
    private CefpackViewAndroidDelegate mViewAndroidDelegate;
    private WebContents mWebContents;
    private NavigationController mNavigationController;

    private long mNativeSessionPtr;
    private boolean mClosed;
    private int mNextDevToolsCallId = 1;
    private final SparseArray<DevToolsResultCallback> mDevToolsCallbacks = new SparseArray<>();

    private SessionCallback mSessionCallback;
    private RequestInterceptor mRequestInterceptor;
    private PopupHandler mPopupHandler;
    private ColorPickerHandler mColorPickerHandler;
    private ContextMenuListener mContextMenuListener;
    private DevToolsEventListener mDevToolsEventListener;
    private ActionMode.Callback mSelectionCallback;

    public CefpackSession(Context context) {
        ThreadUtils.assertOnUiThread();
        if (!CefpackEngine.isInitialized()) {
            CefpackEngine.initialize(context);
        }
        mContext = context;
        mWindowAndroid = CefpackEngine.createWindowAndroid(context);
        mSurfaceContainer = new FrameLayout(context);

        mRenderView = new ContentViewRenderView(context);
        mRenderView.onNativeLibraryLoaded(mWindowAndroid);
        mSurfaceContainer.addView(
                mRenderView,
                new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT));

        mNativeSessionPtr = CefpackSessionJni.get().createSession(this);
    }

    @CalledByNative
    private void initWebContents(WebContents webContents) {
        mWebContents = webContents;
        mNavigationController = webContents.getNavigationController();
        mContentView = ContentView.createContentView(mContext, webContents);
        mViewAndroidDelegate = new CefpackViewAndroidDelegate(mContentView);

        webContents.setDelegates(
                "156.0.8078.96",
                mViewAndroidDelegate,
                mContentView,
                mWindowAndroid,
                WebContents.createDefaultInternalsHolder());

        installSelectionActionModeCallback();

        mSurfaceContainer.addView(
                mContentView,
                new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT));
        mContentView.setFocusable(true);
        mContentView.setFocusableInTouchMode(true);

        if (mRenderView != null) {
            mRenderView.setCurrentWebContents(webContents);
        }
        webContents.updateWebContentsVisibility(Visibility.VISIBLE);
    }

    private void installSelectionActionModeCallback() {
        if (mWebContents == null) {
            return;
        }
        SelectionPopupController controller =
                SelectionPopupController.fromWebContents(mWebContents);
        if (controller == null) {
            return;
        }
        final ActionModeCallbackHelper helper = controller.getActionModeCallbackHelper();
        controller.setActionModeCallback(
                new ActionModeCallback() {
                    @Override
                    public boolean onCreateActionMode(ActionMode mode, Menu menu) {
                        helper.onCreateActionMode(mode, menu);
                        if (mSelectionCallback != null) {
                            mSelectionCallback.onCreateActionMode(mode, menu);
                        }
                        return true;
                    }

                    @Override
                    public boolean onPrepareActionMode(ActionMode mode, Menu menu) {
                        boolean handled = helper.onPrepareActionMode(mode, menu);
                        if (mSelectionCallback != null) {
                            handled |= mSelectionCallback.onPrepareActionMode(mode, menu);
                        }
                        return handled;
                    }

                    @Override
                    public boolean onActionItemClicked(ActionMode mode, MenuItem item) {
                        if (mSelectionCallback != null
                                && mSelectionCallback.onActionItemClicked(mode, item)) {
                            return true;
                        }
                        return helper.onActionItemClicked(mode, item);
                    }

                    @Override
                    public boolean onDropdownItemClicked(
                            SelectionMenuItem item, boolean closeMenu) {
                        return helper.onDropdownItemClicked(item, closeMenu);
                    }

                    @Override
                    public void onDestroyActionMode(ActionMode mode) {
                        if (mSelectionCallback != null) {
                            mSelectionCallback.onDestroyActionMode(mode);
                        }
                        helper.onDestroyActionMode();
                    }

                    @Override
                    public void onGetContentRect(ActionMode mode, View view, Rect outRect) {
                        helper.onGetContentRect(mode, view, outRect);
                    }
                });
    }

    public FrameLayout getSurfaceContainer() {
        return mSurfaceContainer;
    }

    public void setSessionCallback(SessionCallback callback) {
        mSessionCallback = callback;
    }

    public void setRequestInterceptor(RequestInterceptor interceptor) {
        mRequestInterceptor = interceptor;
    }

    public void setPopupHandler(PopupHandler handler) {
        mPopupHandler = handler;
    }

    public void setColorPickerHandler(ColorPickerHandler handler) {
        mColorPickerHandler = handler;
    }

    public void setOnContextMenuListener(ContextMenuListener listener) {
        mContextMenuListener = listener;
    }

    public void setTextSelectionActionModeCallback(ActionMode.Callback callback) {
        mSelectionCallback = callback;
        installSelectionActionModeCallback();
    }

    public void loadUrl(String url) {
        if (mClosed || mNavigationController == null || url == null) {
            return;
        }
        Log.i(CefpackEngine.LOG_TAG, "loadUrl: " + url);
        mNavigationController.loadUrl(new LoadUrlParams(url));
    }

    public void reload() {
        if (!mClosed && mNavigationController != null) {
            mNavigationController.reload(true);
        }
    }

    public void stopLoading() {
        if (!mClosed && mWebContents != null) {
            mWebContents.stop();
        }
    }

    public boolean canGoBack() {
        return !mClosed && mNavigationController != null && mNavigationController.canGoBack();
    }

    public boolean canGoForward() {
        return !mClosed && mNavigationController != null && mNavigationController.canGoForward();
    }

    public void goBack() {
        if (canGoBack()) {
            mNavigationController.goBack();
        }
    }

    public void goForward() {
        if (canGoForward()) {
            mNavigationController.goForward();
        }
    }

    public String getUrl() {
        if (mClosed || mWebContents == null) {
            return null;
        }
        GURL visible = mWebContents.getVisibleUrl();
        if (visible != null && !visible.isEmpty()) {
            return visible.getSpec();
        }
        GURL committed = mWebContents.getLastCommittedUrl();
        return committed != null ? committed.getSpec() : null;
    }

    public String getTitle() {
        if (mClosed || mWebContents == null) {
            return null;
        }
        return mWebContents.getTitle();
    }

    public List<NavigationEntry> getNavigationEntries() {
        if (mClosed || mNativeSessionPtr == 0) {
            return Collections.emptyList();
        }
        ArrayList<NavigationEntry> entries = new ArrayList<>();
        CefpackSessionJni.get().populateNavigationEntries(mNativeSessionPtr, entries);
        return entries;
    }

    @CalledByNative
    private static void appendNavEntryFromNative(
            Object listObj, String url, String title, boolean isCurrent) {
        @SuppressWarnings("unchecked")
        List<NavigationEntry> list = (List<NavigationEntry>) listObj;
        list.add(new NavigationEntry(url, title, isCurrent));
    }

    public void setZoomLevel(double zoomLevel) {
        if (!mClosed && mNativeSessionPtr != 0) {
            CefpackSessionJni.get().setZoomLevel(mNativeSessionPtr, zoomLevel);
        }
    }

    public void setPageVisible(boolean visible) {
        if (!mClosed && mWebContents != null) {
            if (visible && mRenderView != null) {
                mRenderView.setCurrentWebContents(mWebContents);
            }
            mWebContents.updateWebContentsVisibility(
                    visible ? Visibility.VISIBLE : Visibility.HIDDEN);
        }
    }

    public void onResume() {
        setPageVisible(true);
    }

    public void onPause() {
        setPageVisible(false);
    }

    public void suspendMedia() {
        if (!mClosed && mWebContents != null) {
            mWebContents.suspendAllMediaPlayers();
        }
    }

    public void resumeMedia() {
        if (!mClosed && mNativeSessionPtr != 0) {
            CefpackSessionJni.get().resumeMedia(mNativeSessionPtr);
        }
    }

    public void stopAllMedia() {
        if (!mClosed && mWebContents != null) {
            mWebContents.suspendAllMediaPlayers();
            mWebContents.setAudioMuted(true);
        }
    }

    public void stopMediaSession() {
        stopAllMedia();
        if (!mClosed && mWebContents != null) {
            MediaSession session = MediaSession.fromWebContents(mWebContents);
            if (session != null) {
                session.stop();
            }
        }
    }

    public void setAudioMuted(boolean muted) {
        if (!mClosed && mWebContents != null) {
            mWebContents.setAudioMuted(muted);
        }
    }

    public boolean isAudioMuted() {
        return !mClosed && mWebContents != null && mWebContents.isAudioMuted();
    }

    public boolean isPlayingAudio() {
        return !mClosed
                && mNativeSessionPtr != 0
                && CefpackSessionJni.get().isCurrentlyAudible(mNativeSessionPtr);
    }

    public void exitFullscreen() {
        if (!mClosed && mWebContents != null) {
            mWebContents.exitFullscreen();
        }
    }

    public String getSelectedText() {
        if (mClosed || mWebContents == null) {
            return null;
        }
        SelectionPopupController controller =
                SelectionPopupController.fromWebContents(mWebContents);
        return controller != null ? controller.getSelectedText() : null;
    }

    public void contextMenuCommand(int commandId) {
        // Handled natively via SelectionPopupController ActionMode items and Trap UI actions.
    }

    public void sendMouseMove(int x, int y) {
        if (mClosed || mContentView == null) {
            return;
        }
        long now = SystemClock.uptimeMillis();
        MotionEvent event =
                MotionEvent.obtain(now, now, MotionEvent.ACTION_HOVER_MOVE, (float) x, (float) y, 0);
        event.setSource(InputDevice.SOURCE_MOUSE);
        mContentView.dispatchGenericMotionEvent(event);
        event.recycle();
    }

    public void sendMouseWheel(int x, int y, int deltaX, int deltaY) {
        if (mClosed || mContentView == null) {
            return;
        }
        long now = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties[] props = new MotionEvent.PointerProperties[1];
        props[0] = new MotionEvent.PointerProperties();
        props[0].id = 0;
        props[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;

        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[1];
        coords[0] = new MotionEvent.PointerCoords();
        coords[0].x = (float) x;
        coords[0].y = (float) y;
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, deltaX / 120.0f);
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, deltaY / 120.0f);

        MotionEvent event =
                MotionEvent.obtain(
                        now,
                        now,
                        MotionEvent.ACTION_SCROLL,
                        1,
                        props,
                        coords,
                        0,
                        0,
                        1.0f,
                        1.0f,
                        0,
                        0,
                        InputDevice.SOURCE_MOUSE,
                        0);
        mContentView.dispatchGenericMotionEvent(event);
        event.recycle();
    }

    public void captureBitmap(BitmapCallback callback) {
        if (callback == null) {
            return;
        }
        if (mClosed || mRenderView == null) {
            callback.onBitmapCaptured(null);
            return;
        }
        int width = Math.max(1, mSurfaceContainer.getWidth());
        int height = Math.max(1, mSurfaceContainer.getHeight());
        SurfaceView surfaceView = mRenderView.getSurfaceView();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && surfaceView != null
                && surfaceView.getHolder() != null
                && surfaceView.getHolder().getSurface() != null
                && surfaceView.getHolder().getSurface().isValid()
                && surfaceView.getWidth() > 0
                && surfaceView.getHeight() > 0) {
            Bitmap bmp =
                    Bitmap.createBitmap(
                            surfaceView.getWidth(),
                            surfaceView.getHeight(),
                            Bitmap.Config.ARGB_8888);
            try {
                PixelCopy.request(
                        surfaceView,
                        bmp,
                        copyResult -> {
                            if (copyResult == PixelCopy.SUCCESS) {
                                callback.onBitmapCaptured(bmp);
                            } else {
                                bmp.recycle();
                                callback.onBitmapCaptured(null);
                            }
                        },
                        new Handler(Looper.getMainLooper()));
                return;
            } catch (Throwable ignored) {
                bmp.recycle();
            }
        }
        if (mSurfaceContainer.getWidth() > 0 && mSurfaceContainer.getHeight() > 0) {
            try {
                Bitmap fallback = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                Canvas canvas = new Canvas(fallback);
                mSurfaceContainer.draw(canvas);
                callback.onBitmapCaptured(fallback);
                return;
            } catch (Throwable ignored) {
            }
        }
        callback.onBitmapCaptured(null);
    }

    public void executeDevToolsMethod(
            String method, String paramsJson, DevToolsResultCallback callback) {
        if (mClosed || mNativeSessionPtr == 0 || method == null) {
            if (callback != null) {
                callback.onResult(false, "{\"message\":\"Session closed\"}");
            }
            return;
        }
        int callId = mNextDevToolsCallId++;
        if (callback != null) {
            mDevToolsCallbacks.put(callId, callback);
        }
        CefpackSessionJni.get()
                .executeDevToolsMethod(
                        mNativeSessionPtr, callId, method, paramsJson != null ? paramsJson : "{}");
    }

    public void setDevToolsEventListener(DevToolsEventListener listener) {
        mDevToolsEventListener = listener;
        if (!mClosed && mNativeSessionPtr != 0) {
            CefpackSessionJni.get()
                    .setDevToolsEventsEnabled(mNativeSessionPtr, listener != null);
        }
    }

    public void close() {
        if (mClosed) {
            return;
        }
        mClosed = true;
        for (int i = 0; i < mDevToolsCallbacks.size(); i++) {
            DevToolsResultCallback cb = mDevToolsCallbacks.valueAt(i);
            if (cb != null) {
                cb.onResult(false, "{\"message\":\"Session closed\"}");
            }
        }
        mDevToolsCallbacks.clear();

        if (mRenderView != null) {
            mRenderView.setCurrentWebContents(null);
        }
        long ptr = mNativeSessionPtr;
        mNativeSessionPtr = 0;
        mWebContents = null;
        mNavigationController = null;
        if (ptr != 0) {
            CefpackSessionJni.get().destroySession(ptr);
        }
        if (mRenderView != null) {
            mRenderView.destroy();
            mRenderView = null;
        }
        mSurfaceContainer.removeAllViews();
        if (mWindowAndroid != null) {
            mWindowAndroid.destroy();
            mWindowAndroid = null;
        }
        mContentView = null;
        mViewAndroidDelegate = null;
    }

    @CalledByNative
    private boolean shouldBlockRequestFromNative(
            String url,
            String method,
            boolean isMainFrame,
            String resourceType,
            String topLevelUrl) {
        RequestInterceptor interceptor = mRequestInterceptor;
        if (interceptor == null) {
            return false;
        }
        try {
            return interceptor.shouldBlockRequest(
                    url, method, isMainFrame, resourceType, topLevelUrl);
        } catch (Throwable t) {
            Log.w(CefpackEngine.LOG_TAG, "RequestInterceptor threw; failing closed", t);
            return true;
        }
    }

    @CalledByNative
    private boolean onPopupRequestedFromNative(String targetUrl, boolean userGesture) {
        PopupHandler handler = mPopupHandler;
        return handler != null && handler.onPopupRequested(targetUrl, userGesture);
    }

    @CalledByNative
    private boolean onColorChooserFromNative(int initialColor) {
        ColorPickerHandler handler = mColorPickerHandler;
        if (handler == null) {
            return false;
        }
        return handler.onShowColorPicker(
                initialColor,
                new ColorCallback() {
                    @Override
                    public void onColorSelected(int argbColor) {
                        if (!mClosed && mNativeSessionPtr != 0) {
                            CefpackSessionJni.get()
                                    .resolveColorChooser(mNativeSessionPtr, true, argbColor);
                        }
                    }

                    @Override
                    public void onDismissed() {
                        if (!mClosed && mNativeSessionPtr != 0) {
                            CefpackSessionJni.get()
                                    .resolveColorChooser(mNativeSessionPtr, false, 0);
                        }
                    }
                });
    }

    @CalledByNative
    private boolean onContextMenuFromNative(String linkUrl, String srcUrl, String selectionText) {
        ContextMenuListener listener = mContextMenuListener;
        if (listener == null) {
            return false;
        }
        listener.onContextMenu(linkUrl, srcUrl, selectionText);
        return true;
    }

    @CalledByNative
    private void onUrlChangedFromNative(String url) {
        if (mSessionCallback != null) {
            mSessionCallback.onUrlChanged(url);
        }
    }

    @CalledByNative
    private void onTitleChangedFromNative(String title) {
        if (mSessionCallback != null) {
            mSessionCallback.onTitleChanged(title);
        }
    }

    @CalledByNative
    private void onLoadingProgressFromNative(int progress) {
        if (mSessionCallback != null) {
            mSessionCallback.onLoadingProgress(progress);
        }
    }

    @CalledByNative
    private void onLoadingStateFromNative(
            boolean isLoading, boolean canGoBack, boolean canGoForward) {
        if (mSessionCallback != null) {
            mSessionCallback.onLoadingStateChanged(isLoading, canGoBack, canGoForward);
        }
    }

    @CalledByNative
    private void onLoadStartFromNative(String url) {
        if (mSessionCallback != null) {
            mSessionCallback.onLoadStart(url);
        }
    }

    @CalledByNative
    private void onLoadEndFromNative(int httpStatusCode, boolean isPrimaryMainFrame, String url) {
        Log.i(
                CefpackEngine.LOG_TAG,
                "OnLoadEnd: status " + httpStatusCode + ", isMain=" + (isPrimaryMainFrame ? 1 : 0));
        if (mSessionCallback != null) {
            mSessionCallback.onLoadEnd(httpStatusCode, isPrimaryMainFrame, url);
        }
    }

    @CalledByNative
    private void onLoadErrorFromNative(int errorCode, String errorText, String failedUrl) {
        if (mSessionCallback != null) {
            mSessionCallback.onLoadError(errorCode, errorText, failedUrl);
        }
    }

    @CalledByNative
    private void onDocumentAvailableFromNative() {
        if (mSessionCallback != null) {
            mSessionCallback.onDocumentAvailable();
        }
    }

    @CalledByNative
    private void onFullscreenChangedFromNative(boolean isFullscreen) {
        if (mSessionCallback != null) {
            mSessionCallback.onFullscreenChanged(isFullscreen);
        }
    }

    @CalledByNative
    private void onAudioStateChangedFromNative(boolean isPlaying) {
        if (mSessionCallback != null) {
            mSessionCallback.onAudioStateChanged(isPlaying);
        }
    }

    @CalledByNative
    private void onMediaAccessChangedFromNative(boolean hasVideo, boolean hasAudio) {
        if (mSessionCallback != null) {
            mSessionCallback.onMediaAccessChange(hasVideo, hasAudio);
        }
    }

    @CalledByNative
    private void onDevToolsResultFromNative(int callId, boolean success, String json) {
        DevToolsResultCallback cb = mDevToolsCallbacks.get(callId);
        mDevToolsCallbacks.remove(callId);
        if (cb != null) {
            cb.onResult(success, json);
        }
    }

    @CalledByNative
    private void onDevToolsEventFromNative(String method, String paramsJson) {
        if (mDevToolsEventListener != null) {
            mDevToolsEventListener.onEvent(method, paramsJson);
        }
    }

    @NativeMethods
    interface Natives {
        long createSession(CefpackSession javaSession);

        void destroySession(long sessionPtr);

        void setZoomLevel(long sessionPtr, double zoomLevel);

        void resumeMedia(long sessionPtr);

        boolean isCurrentlyAudible(long sessionPtr);

        void populateNavigationEntries(long sessionPtr, Object outList);

        void executeDevToolsMethod(
                long sessionPtr, int callId, String method, String paramsJson);

        void setDevToolsEventsEnabled(long sessionPtr, boolean enabled);

        void resolveColorChooser(long sessionPtr, boolean selected, int argbColor);
    }
}
