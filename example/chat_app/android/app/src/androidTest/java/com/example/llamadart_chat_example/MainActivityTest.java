package com.example.llamadart_chat_example;

import android.app.Instrumentation;
import android.content.Context;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.Process;
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

    // Null for a blank value: a runner that passes an optional argument as an
    // empty string means the default, and JSONObject.put drops a null value.
    private static String optional(Bundle arguments, String name) {
        String value = arguments.getString(name);
        return value == null || value.trim().isEmpty() ? null : value;
    }

    // Next to the journal: the Vulkan driver's own limits, from which a WebGPU
    // limit that a run trips over is derived, and the hash of the installed
    // app APK, which names the runtime libraries the run loaded.
    private static void saveDeviceFacts(Instrumentation instrumentation) {
        try {
            Context context = instrumentation.getTargetContext();
            File directory = new File(context.getExternalFilesDir(null), "litert_reload_memory");
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
        saveDeviceFacts(instrumentation);
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
