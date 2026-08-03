package com.timememo.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.lang.ref.WeakReference;

/**
 * 「时光记忆 · TimeMemo」应用外壳：一个全屏 WebView，加载打包在 assets 中的本地页面。
 * 数据通过 localStorage 存在应用私有目录，全程不联网。
 */
public class MainActivity extends Activity {

    private static final String TAG = "TimeMemo";
    private static final int COLOR_DARK = 0xFF0F1220;
    private static final int COLOR_LIGHT = 0xFFEEF1F8;

    private WebView web;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            setupUi();
        } catch (Throwable t) {
            // 任何初始化异常都不允许直接闪退，改为展示可读的错误信息
            Log.e(TAG, "init failed", t);
            showFallback(t);
        }
    }

    private void setupUi() {
        Window window = getWindow();
        window.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
        window.setStatusBarColor(COLOR_DARK);
        window.setNavigationBarColor(COLOR_DARK);

        web = new WebView(this);
        web.setBackgroundColor(COLOR_DARK);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        // localStorage 依赖，务必开启
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setDisplayZoomControls(false);
        s.setLoadWithOverviewMode(false);
        s.setUseWideViewPort(true);
        // 固定文字缩放，避免系统超大字体撑破布局
        s.setTextZoom(100);
        s.setMediaPlaybackRequiresUserGesture(true);

        // 页面自带明暗主题，禁止系统强制反色。部分厂商 ROM 会抛异常，单独兜底。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
                && Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            try {
                s.setForceDark(WebSettings.FORCE_DARK_OFF);
            } catch (Throwable ignored) {
                Log.w(TAG, "setForceDark unsupported");
            }
        }

        // 默认 WebChromeClient 才能让页面里的 alert / confirm 正常弹出
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient());
        web.addJavascriptInterface(new Bridge(this), "AndroidBridge");

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(COLOR_DARK);
        root.addView(web, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT));
        setContentView(root);

        web.loadUrl("file:///android_asset/index.html");
    }

    /** 初始化失败时的兜底界面，便于定位问题而不是直接闪退 */
    private void showFallback(Throwable t) {
        try {
            TextView tv = new TextView(this);
            tv.setText("应用启动遇到问题\n\n"
                    + t.getClass().getSimpleName() + "\n"
                    + String.valueOf(t.getMessage())
                    + "\n\n请把这段信息反馈给开发者。");
            tv.setTextColor(Color.WHITE);
            tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f);
            tv.setPadding(48, 96, 48, 48);
            tv.setGravity(Gravity.START);

            ScrollView sv = new ScrollView(this);
            sv.setBackgroundColor(COLOR_DARK);
            sv.addView(tv);
            setContentView(sv);
        } catch (Throwable ignored) {
            // 兜底的兜底：放弃
        }
    }

    /**
     * 供页面调用，让系统状态栏 / 导航栏跟随应用内主题。
     * 使用静态类 + 弱引用，避免隐式持有 Activity 造成泄漏。
     */
    public static class Bridge {
        private final WeakReference<MainActivity> ref;

        Bridge(MainActivity activity) {
            this.ref = new WeakReference<MainActivity>(activity);
        }

        @JavascriptInterface
        public void setTheme(final String theme) {
            final MainActivity a = ref.get();
            if (a == null || a.isFinishing()) return;
            final boolean dark = !"light".equals(theme);
            a.runOnUiThread(new Runnable() {
                @Override
                public void run() {
                    a.applySystemBars(dark);
                }
            });
        }
    }

    private void applySystemBars(boolean dark) {
        try {
            int color = dark ? COLOR_DARK : COLOR_LIGHT;
            Window w = getWindow();
            w.setStatusBarColor(color);
            w.setNavigationBarColor(color);
            if (web != null) web.setBackgroundColor(color);

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                View decor = w.getDecorView();
                int flags = decor.getSystemUiVisibility();
                if (dark) {
                    flags &= ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
                } else {
                    flags |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    if (dark) {
                        flags &= ~View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
                    } else {
                        flags |= View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
                    }
                }
                decor.setSystemUiVisibility(flags);
            }
        } catch (Throwable ignored) {
            Log.w(TAG, "applySystemBars failed");
        }
    }

    @Override
    public void onBackPressed() {
        // 单页应用：返回键退到桌面，保留应用状态而不是直接销毁
        moveTaskToBack(true);
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.removeAllViews();
            web.destroy();
            web = null;
        }
        super.onDestroy();
    }
}
