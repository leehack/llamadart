package com.example.llamadart_chat_example;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.rule.ActivityTestRule;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import org.json.JSONException;
import org.json.JSONObject;
import org.junit.Rule;
import org.junit.runner.RunWith;

@RunWith(FlutterTestRunner.class)
public class MainActivityTest {
    private static final String TAG = "MainActivityTest";

    // FlutterTestRunner constructs this class before launch, without JUnit @Before.
    public MainActivityTest() throws IOException {
        Bundle arguments = InstrumentationRegistry.getArguments();
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        if ("true".equals(arguments.getString("stageModel"))) stageModel(instrumentation);
        forwardReloadMemoryArguments(arguments, instrumentation);
        forwardMicroBatchSweepArguments(arguments, instrumentation);
        forwardAndroidQualificationArguments(arguments, instrumentation);
    }

    private static void stageModel(Instrumentation instrumentation) throws IOException {
        File destination = new File(instrumentation.getTargetContext().getCacheDir(), "firebase-model.gguf");
        File temporary = new File(destination.getPath() + ".tmp");
        boolean copied = false;
        try {
            // Read the shell-owned Test Lab file through a shell descriptor,
            // writing as the app. No production storage permission is required.
            ParcelFileDescriptor descriptor = instrumentation.getUiAutomation()
                .executeShellCommand("cat /data/local/tmp/llamadart-smoke.gguf");
            try (InputStream input = new ParcelFileDescriptor.AutoCloseInputStream(descriptor);
                 FileOutputStream output = new FileOutputStream(temporary)) {
                byte[] buffer = new byte[1024 * 1024];
                int count;
                while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            }
            if (temporary.length() == 0 || !temporary.renameTo(destination)) {
                throw new IOException("Unable to stage Firebase model into app cache");
            }
            copied = true;
        } finally {
            if (!copied) temporary.delete();
        }
        // Dart verifies the exact model SHA-256 before inference.
    }

    // Hands litert_lm_reload_memory_e2e_test.dart its instrumentation
    // arguments. The pid lets Dart ignore a file left by an earlier process.
    private static void forwardReloadMemoryArguments(Bundle arguments, Instrumentation instrumentation)
            throws IOException {
        File cache = instrumentation.getTargetContext().getCacheDir();
        File file = new File(cache, "litert_reload_memory_args.json");
        boolean snapshots = "true".equals(arguments.getString("memorySnapshots"));
        JSONObject json = new JSONObject();
        try {
            json.put("variants", optional(arguments, "litertReloadVariants"));
            json.put("iterations", optional(arguments, "litertReloadIterations"));
            json.put("prompts", optional(arguments, "litertReloadPrompts"));
            json.put("chat", optional(arguments, "litertReloadChat"));
            json.put("temperature", optional(arguments, "litertReloadTemperature"));
            json.put("seed", optional(arguments, "litertReloadSeed"));
            if (json.length() == 0 && !snapshots) {
                file.delete();
                return;
            }
            json.put("pid", Process.myPid());
            json.put("snapshots", snapshots);
        } catch (JSONException error) {
            throw new IOException(error);
        }
        write(file, json.toString());
        if (snapshots) startDumpsysResponder(instrumentation, cache);
    }

    // Hands micro_batch_sweep_e2e_test.dart its instrumentation arguments, and
    // with any of them saves the device facts next to its journal.
    private static void forwardMicroBatchSweepArguments(Bundle arguments, Instrumentation instrumentation)
            throws IOException {
        File file = new File(instrumentation.getTargetContext().getCacheDir(), "micro_batch_sweep_args.json");
        JSONObject json = new JSONObject();
        try {
            json.put("arms", optional(arguments, "microBatchArms"));
            json.put("repeats", optional(arguments, "microBatchRepeats"));
            json.put("budget_seconds", optional(arguments, "microBatchBudgetSeconds"));
            json.put("profile", optional(arguments, "microBatchProfile"));
            json.put("native_log", optional(arguments, "microBatchNativeLog"));
            json.put("device", optional(arguments, "microBatchDevice"));
            if (json.length() == 0) {
                file.delete();
                return;
            }
            json.put("pid", Process.myPid());
        } catch (JSONException error) {
            throw new IOException(error);
        }
        write(file, json.toString());
        // Connect UiAutomation before Flutter starts, as the dumpsys responder does.
        instrumentation.getUiAutomation();
        saveDeviceFacts(instrumentation, "micro_batch_sweep");
    }

    // Null for a blank value: a runner that passes an optional argument as an
    // empty string means the default, and JSONObject.put drops a null value.
    private static String optional(Bundle arguments, String name) {
        String value = arguments.getString(name);
        return value == null || value.trim().isEmpty() ? null : value;
    }

    private static void forwardAndroidQualificationArguments(Bundle arguments,
            Instrumentation instrumentation) throws IOException {
        String scenario = arguments.getString("androidQualificationScenario");
        if (scenario == null) return;
        if (!scenario.equals("a35") && !scenario.equals("pixel8a") && !scenario.equals("consumer-cpu")) {
            throw new IOException("Unknown Android qualification scenario");
        }
        Context context = instrumentation.getTargetContext();
        File cache = context.getCacheDir();
        File request = new File(cache, "android_qualification_watchdog.json");
        if (request.exists()) throw new IOException("Stale qualification watchdog request");
        String nonce = java.util.UUID.randomUUID().toString();
        JSONObject config = new JSONObject();
        try (InputStream input = context.getAssets().open("llamadart_android_qualification/binding.json")) {
            config.put("binding", new JSONObject(new String(input.readAllBytes(), StandardCharsets.UTF_8)));
            config.put("scenario", scenario);
            if (scenario.equals("consumer-cpu")) {
                String deviceClass = arguments.getString("androidConsumerDeviceClass");
                String model = arguments.getString("androidConsumerDeviceModel");
                String api = arguments.getString("androidConsumerDeviceApi");
                if (!("old".equals(deviceClass) || "modern".equals(deviceClass)) ||
                        model == null || api == null || !Build.MODEL.equals(model) ||
                        !Integer.toString(Build.VERSION.SDK_INT).equals(api)) {
                    throw new IOException("Missing or mismatched prospective consumer device tuple");
                }
                config.put("consumer_device_class", deviceClass);
            }
            config.put("pid", Process.myPid());
            config.put("nonce", nonce);
            config.put("native_directory", context.getApplicationInfo().nativeLibraryDir);
            config.put("device_model", Build.MODEL);
            config.put("device_manufacturer", Build.MANUFACTURER);
            config.put("device_build", Build.FINGERPRINT);
            config.put("android_api", Build.VERSION.SDK_INT);
            config.put("soc_model", Build.VERSION.SDK_INT >= 31 ? Build.SOC_MODEL : "unknown");
            File output = new File(context.getExternalFilesDir(null), "android_qualification/" + nonce);
            if (output.exists() || !output.mkdirs()) throw new IOException("Qualification output already exists");
            config.put("output", output.getPath());
            write(new File(cache, "android_qualification_args.json"), config.toString());
            instrumentation.getUiAutomation();
            saveDeviceFacts(instrumentation, "android_qualification/" + nonce);
            startQualificationWatchdog(request, output, nonce);
        } catch (JSONException error) {
            throw new IOException(error);
        }
    }

    // A Flutter Future timeout cannot stop native work. This Java thread owns
    // the entire test process deadline independently of the Dart event loop.
    private static void startQualificationWatchdog(File request, File output, String nonce) {
        Thread watcher = new Thread(() -> {
            final long runStarted = SystemClock.elapsedRealtime();
            long armedAt = 0;
            long timeout = 0;
            String step = "";
            while (!Thread.currentThread().isInterrupted()) {
                try {
                    if (new File(output, "watchdog.done").isFile()) return;
                    if (SystemClock.elapsedRealtime() - runStarted >= 20L * 60 * 1000) {
                        throw new IOException("Qualification run deadline exceeded");
                    }
                    if (!request.exists()) { armedAt = 0; step = ""; }
                    else {
                        String requestJson = StandardCharsets.UTF_8.newDecoder()
                            .decode(java.nio.ByteBuffer.wrap(java.nio.file.Files.readAllBytes(request.toPath())))
                            .toString();
                        JSONObject value = new JSONObject(requestJson);
                        if (!nonce.equals(value.getString("nonce")) || value.getInt("pid") != Process.myPid()) {
                            throw new IOException("Qualification watchdog binding mismatch");
                        }
                        String current = value.getString("step");
                        if (!current.equals(step)) {
                            timeout = value.getLong("timeout_ms");
                            if (timeout <= 0 || timeout > 120000) throw new IOException("Invalid qualification deadline");
                            step = current;
                            armedAt = SystemClock.elapsedRealtime();
                        }
                        if (SystemClock.elapsedRealtime() - armedAt >= timeout) {
                            write(new File(output, "watchdog-failure.json"),
                                "{\"qualified\":false,\"reason\":\"public_process_deadline\"}");
                            Process.killProcess(Process.myPid());
                            return;
                        }
                        File[] logs = output.listFiles((directory, name) -> name.endsWith(".stderr.log"));
                        if (logs == null) throw new IOException("Qualification output unavailable");
                        for (File log : logs) {
                            if (log.length() > 8L * 1024 * 1024) {
                                throw new IOException("Public native stderr exceeds capture bound");
                            }
                        }
                    }
                    Thread.sleep(25);
                } catch (java.nio.file.NoSuchFileException error) {
                    // Dart can disarm between exists() and the atomic-file read.
                    armedAt = 0;
                    step = "";
                } catch (InterruptedException error) { return; }
                catch (IOException | JSONException | RuntimeException error) {
                    try { write(new File(output, "watchdog-failure.json"),
                        "{\"qualified\":false,\"reason\":\"watchdog_protocol_failed\"}"); }
                    catch (IOException ignored) { }
                    Process.killProcess(Process.myPid());
                    return;
                }
            }
        }, "android-qualification-deadline");
        watcher.setDaemon(true);
        watcher.start();
    }

    // Next to the journal: the Vulkan driver's own limits, from which a WebGPU
    // limit that a run trips over is derived, and the hash of the installed
    // app APK, which names the runtime libraries the run loaded.
    private static void saveDeviceFacts(Instrumentation instrumentation, String output) {
        try {
            Context context = instrumentation.getTargetContext();
            File directory = new File(context.getExternalFilesDir(null), output);
            if (!directory.isDirectory() && !directory.mkdirs()) {
                throw new IOException("Unable to create " + directory);
            }
            write(new File(directory, "vkjson.json"), shell(instrumentation, "cmd gpu vkjson"));
            write(new File(directory, "app_apk.sha256"),
                shell(instrumentation, "sha256sum " + context.getPackageCodePath()));
        } catch (IOException | RuntimeException error) {
            Log.w(TAG, "Unable to save device facts", error);
        }
    }

    // dumpsys needs the shell's DUMP permission, which the app does not hold,
    // so the Dart test asks for it through a request file.
    private static void startDumpsysResponder(Instrumentation instrumentation, File cache) {
        String packageName = instrumentation.getTargetContext().getPackageName();
        File request = new File(cache, "litert_reload_memory.request");
        File response = new File(cache, "litert_reload_memory.response");
        request.delete();
        response.delete();
        // Connecting UiAutomation turns on accessibility, and with it Flutter
        // semantics. Connect before Flutter starts: a semantics handle that
        // appears during the test fails it at the end.
        instrumentation.getUiAutomation();
        saveDeviceFacts(instrumentation, "litert_reload_memory");
        Thread responder = new Thread(() -> {
            while (true) {
                try {
                    if (request.exists()) {
                        File temporary = new File(response.getPath() + ".tmp");
                        try {
                            write(temporary, shell(instrumentation, "dumpsys meminfo " + packageName)
                                + "\n" + shell(instrumentation, "dumpsys gpu --gpumem"));
                        } finally {
                            request.delete();
                        }
                        if (!temporary.renameTo(response)) {
                            throw new IOException("Unable to publish dumpsys response");
                        }
                    }
                    Thread.sleep(50);
                } catch (InterruptedException error) {
                    return;
                } catch (IOException | RuntimeException error) {
                    // The Dart test times out on the missing response and
                    // records that dumpsys was unavailable.
                    Log.w(TAG, "dumpsys request failed", error);
                }
            }
        }, "litert-reload-memory-dumpsys");
        responder.setDaemon(true);
        responder.start();
    }

    private static String shell(Instrumentation instrumentation, String command) throws IOException {
        ParcelFileDescriptor descriptor = instrumentation.getUiAutomation().executeShellCommand(command);
        try (InputStream input = new ParcelFileDescriptor.AutoCloseInputStream(descriptor)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            return output.toString("UTF-8");
        }
    }

    private static void write(File file, String text) throws IOException {
        try (FileOutputStream output = new FileOutputStream(file)) {
            output.write(text.getBytes(StandardCharsets.UTF_8));
        }
    }

    @Rule
    public ActivityTestRule<MainActivity> rule =
        new ActivityTestRule<>(MainActivity.class, true, false);
}
