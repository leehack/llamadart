package dev.llamadart.studio;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Closed shell input names; no caller-supplied paths or URLs reach a command. */
final class MobileDefaultModelStaging {
    static final String DIRECTORY = "studio-mobile-default-models";
    static final String[] NAMES = {
        "Qwen3.5-0.8B-Q4_K_M.gguf", "Qwen3.5-0.8B-mmproj-F16.gguf"
    };
    static final long[] SIZES = {532517120L, 204987232L};
    static final String[] HASHES = {
        "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
        "56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453"
    };

    interface Source { InputStream open(String name) throws IOException; }

    static void stage(File cache, Source source) throws IOException {
        File root = new File(cache, DIRECTORY);
        // Never accept stale or partially staged input from another attempt.
        if (!root.mkdir()) throw new IOException("Fresh mobile default stage required");
        for (int i = 0; i < NAMES.length; i++) {
            try (InputStream input = source.open(NAMES[i])) {
                copyVerified(input, new File(root, NAMES[i]), SIZES[i], HASHES[i]);
            }
        }
        String manifest = "{\"schema\":1,\"assets\":{\"" + NAMES[0]
            + "\":{\"bytes\":" + SIZES[0] + ",\"sha256\":\"" + HASHES[0]
            + "\"},\"" + NAMES[1] + "\":{\"bytes\":" + SIZES[1]
            + ",\"sha256\":\"" + HASHES[1] + "\"}}}";
        try (FileOutputStream output = new FileOutputStream(new File(root, "manifest.json"))) {
            output.write(manifest.getBytes(StandardCharsets.UTF_8));
            output.getFD().sync();
        }
    }

    static void copyVerified(InputStream input, File destination, long size, String hash)
            throws IOException {
        File temporary = new File(destination.getPath() + ".tmp");
        boolean published = false;
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            long bytes = 0;
            try (FileOutputStream output = new FileOutputStream(temporary)) {
                byte[] buffer = new byte[1024 * 1024];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    bytes += count;
                    if (bytes > size) throw new IOException("Oversize mobile asset");
                    digest.update(buffer, 0, count);
                    output.write(buffer, 0, count);
                }
                output.getFD().sync();
            }
            StringBuilder actual = new StringBuilder();
            for (byte value : digest.digest()) actual.append(String.format("%02x", value & 255));
            if (bytes != size || !actual.toString().equals(hash) || !temporary.renameTo(destination)) {
                throw new IOException("Mobile asset size/hash/publication mismatch");
            }
            published = true;
        } catch (NoSuchAlgorithmException error) { throw new IOException(error); }
        finally { if (!published) temporary.delete(); }
    }
}
