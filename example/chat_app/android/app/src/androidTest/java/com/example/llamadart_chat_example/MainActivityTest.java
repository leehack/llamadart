package com.example.llamadart_chat_example;

import android.app.Instrumentation;
import android.os.ParcelFileDescriptor;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.rule.ActivityTestRule;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import dev.flutter.plugins.integration_test.FlutterTestRunner;
import org.junit.Rule;
import org.junit.runner.RunWith;

@RunWith(FlutterTestRunner.class)
public class MainActivityTest {
    // FlutterTestRunner constructs this class before launch, without JUnit @Before.
    public MainActivityTest() throws IOException {
        if (!"true".equals(InstrumentationRegistry.getArguments().getString("stageModel"))) return;
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
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

    @Rule
    public ActivityTestRule<MainActivity> rule =
        new ActivityTestRule<>(MainActivity.class, true, false);
}
