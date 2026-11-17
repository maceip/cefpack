// Copyright 2026 The Cefpack Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package dev.cefpack.android;

import android.view.ViewGroup;

import org.chromium.ui.base.ViewAndroidDelegate;

/** ViewAndroidDelegate implementation backing a CefpackSession ContentView container. */
public class CefpackViewAndroidDelegate extends ViewAndroidDelegate {
    public CefpackViewAndroidDelegate(ViewGroup containerView) {
        super(containerView);
    }
}
