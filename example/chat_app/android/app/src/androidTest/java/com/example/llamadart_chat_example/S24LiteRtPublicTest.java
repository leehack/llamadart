package com.example.llamadart_chat_example;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Build;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.os.SystemClock;
import java.util.UUID;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.rule.ActivityTestRule;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import org.json.JSONObject;
import org.junit.Rule;
import org.junit.runner.RunWith;

/** Separate class: a frozen Test Lab submission must select only this target. */
@RunWith(FlutterTestRunner.class)
public class S24LiteRtPublicTest {
    public S24LiteRtPublicTest() throws Exception {
        Bundle args = InstrumentationRegistry.getArguments();
        if (!"s24-litert-public-v1".equals(args.getString("qualificationMode"))) {
            throw new IOException("Explicit S24 qualification mode required");
        }
        String expected = args.getString("qualificationBindingSha256", "");
        if (!expected.matches("[a-f0-9]{64}")) {
            throw new IOException("An admitted final binding hash is required");
        }
        if (!"SC-51E".equals(Build.MODEL) || Build.VERSION.SDK_INT != 36 || !Build.SOC_MODEL.contains("SM8650")) {
            throw new IOException("Exact SC-51E/API36/SM8650 device required");
        }
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        Context context = instrumentation.getTargetContext();
        File stage = new File(context.getCacheDir(), "s24-litert-public");
        if (!stage.mkdir()) throw new IOException("Fresh S24 staging directory required");
        File bindingFile = copy(instrumentation, "binding.json", stage);
        byte[] raw = java.nio.file.Files.readAllBytes(bindingFile.toPath());
        if (!hex(MessageDigest.getInstance("SHA-256").digest(raw)).equals(expected)) {
            throw new IOException("Binding bytes differ from admitted input");
        }
        JSONObject binding = new JSONObject(new String(raw, StandardCharsets.UTF_8));
        String runId = binding.getString("run_id");
        if (!runId.matches("[A-Za-z0-9][A-Za-z0-9_-]{0,79}")) {
            throw new IOException("Invalid S24 run id");
        }
        File output = new File(context.getExternalFilesDir(null), runId);
        if (!output.mkdir()) throw new IOException("Fresh S24 output directory required");
        String nonce = UUID.randomUUID().toString();
        File watchdog = new File(context.getCacheDir(), "s24_litert_watchdog.json");
        if (watchdog.exists()) throw new IOException("Stale S24 watchdog state");
        JSONObject initial = new JSONObject().put("pid", Process.myPid()).put("nonce", nonce)
            .put("step", -1).put("timeout_ms", 120000);
        try (FileOutputStream stream = new FileOutputStream(watchdog)) {
            stream.write(initial.toString().getBytes(StandardCharsets.UTF_8)); stream.getFD().sync();
        }
        startWatchdog(watchdog, output, nonce);
        copy(instrumentation, "cpu.litertlm", stage);
        copy(instrumentation, "gpu.litertlm", stage);
        copy(instrumentation, "template.jinja", stage);
        JSONObject config = new JSONObject();
        config.put("pid", Process.myPid());
        config.put("watchdog", watchdog.getCanonicalPath());
        config.put("nonce", nonce);
        config.put("binding", binding);
        config.put("binding_sha256", expected);
        config.put("stage", stage.getCanonicalPath());
        config.put("output", output.getCanonicalPath());
        config.put("native_directory", context.getApplicationInfo().nativeLibraryDir);
        config.put("device", new JSONObject()
            .put("model", Build.MODEL).put("manufacturer", Build.MANUFACTURER)
            .put("api", Build.VERSION.SDK_INT).put("build", Build.FINGERPRINT)
            .put("soc", Build.SOC_MODEL).put("hardware", Build.HARDWARE));
        File destination = new File(context.getCacheDir(), "s24_litert_public_args.json");
        if (destination.exists()) throw new IOException("Stale S24 argument receipt");
        try (FileOutputStream stream = new FileOutputStream(destination)) {
            stream.write(config.toString().getBytes(StandardCharsets.UTF_8));
            stream.getFD().sync();
        }
    }

    private static void startWatchdog(File file, File output, String nonce) {
        final int ownedPid = Process.myPid();
        Thread thread = new Thread(() -> {
            long started = SystemClock.elapsedRealtime(), phaseStarted = started;
            int step = -1;
            try {
                while (true) {
                    JSONObject state = new JSONObject(new String(
                        java.nio.file.Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8));
                    if (state.getInt("pid") != ownedPid || !nonce.equals(state.getString("nonce"))) {
                        throw new IOException("S24 watchdog identity mismatch");
                    }
                    if (state.optBoolean("finished", false)) return;
                    int next = state.getInt("step"), timeout = state.getInt("timeout_ms");
                    if (next < step || timeout <= 0 || timeout > 150000) {
                        throw new IOException("S24 watchdog stage bounds changed");
                    }
                    long now = SystemClock.elapsedRealtime();
                    if (next != step) { step = next; phaseStarted = now; }
                    if (now - phaseStarted > timeout || now - started > 1140000) {
                        throw new IOException("S24 owned process deadline exceeded");
                    }
                    for (File entry : output.listFiles()) {
                        if ((entry.getName().endsWith(".stderr") && entry.length() > 8388608) ||
                            (entry.getName().endsWith(".jsonl") && entry.length() > 16777216)) {
                            throw new IOException("S24 public capture byte limit exceeded");
                        }
                    }
                    Thread.sleep(100);
                }
            } catch (Exception failure) {
                try (FileOutputStream stream = new FileOutputStream(new File(output, "watchdog-failure.json"))) {
                    stream.write(("{\"failed\":true,\"pid\":" + ownedPid + "}").getBytes(StandardCharsets.UTF_8));
                    stream.getFD().sync();
                } catch (IOException ignored) { }
                Process.killProcess(ownedPid);
            }
        }, "s24-litert-watchdog");
        thread.setDaemon(true); thread.start();
    }

    private static File copy(Instrumentation instrumentation, String name, File stage)
            throws IOException {
        // Names come only from the fixed calls above; no shell text comes from args.
        File destination = new File(stage, name);
        ParcelFileDescriptor descriptor = instrumentation.getUiAutomation()
            .executeShellCommand("cat /data/local/tmp/s24-litert-public-" + name);
        try (InputStream input = new ParcelFileDescriptor.AutoCloseInputStream(descriptor);
             FileOutputStream output = new FileOutputStream(destination)) {
            byte[] buffer = new byte[1024 * 1024];
            long total = 0;
            int count;
            while ((count = input.read(buffer)) != -1) {
                total += count;
                if (total > (name.equals("binding.json") || name.equals("template.jinja") ? 1048576 : 620000000)) throw new IOException("Oversized S24 input");
                output.write(buffer, 0, count);
            }
            output.getFD().sync();
            if (total == 0) throw new IOException("Missing staged S24 input");
        }
        return destination;
    }

    private static String hex(byte[] value) {
        StringBuilder result = new StringBuilder();
        for (byte item : value) result.append(String.format("%02x", item & 255));
        return result.toString();
    }

    @Rule public ActivityTestRule<MainActivity> activityRule =
        new ActivityTestRule<>(MainActivity.class, true, false);
}
