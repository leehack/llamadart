package dev.llamadart.validation.perfetto;

import java.nio.charset.StandardCharsets;

/** Fixed v49-compatible session acknowledgment and finite scratch-file transport. */
public final class CaptureProtocol {
    private CaptureProtocol() {}

    public static String path(String nonce) {
        if (!nonce.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")) {
            throw new IllegalArgumentException("Fresh UUID required");
        }
        return "/data/local/tmp/llamadart-perfetto-" + nonce;
    }

    public static String startScript(String nonce, String config) {
        if (config.contains("LLAMADART_PERFETTO_CONFIG")) throw new IllegalArgumentException("Invalid config delimiter");
        String path = path(nonce);
        // Redirect the daemon's inherited descriptors to fresh scratch files.
        // The foreground shell's stdout then closes after the session ack.
        return "test ! -e " + path + ".trace && test ! -e " + path + ".pid && test ! -e " + path
            + ".stderr || exit 1; perfetto --background-wait --txt -c - -o " + path
            + ".trace > " + path + ".pid 2> " + path
            + ".stderr <<\"LLAMADART_PERFETTO_CONFIG\"\n" + config + "\nLLAMADART_PERFETTO_CONFIG\ncode=$?; if [ $code -eq 0 ]; then cat " + path
            + ".pid; printf \"READY:0\\n\"; else printf \"READY:ERROR\\n\"; fi";
    }

    public static int startedPid(byte[] acknowledgment) {
        String value = new String(acknowledgment, StandardCharsets.UTF_8);
        if (!value.matches("[1-9][0-9]{0,8}\\nREADY:0\\n")) {
            throw new IllegalStateException("Perfetto session did not acknowledge all sources started");
        }
        return Integer.parseInt(value.substring(0, value.indexOf('\n')));
    }

    public static String completedTraceScript(String nonce, int pid) {
        if (pid <= 0) throw new IllegalArgumentException("Positive acknowledged PID required");
        String path = path(nonce);
        // No signal is sent: the finite 15-second config stops its own process.
        return "for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do "
            + "if ! kill -0 " + pid + " 2>/dev/null; then cat " + path
            + ".trace; exit; fi; sleep 1; done; exit 1";
    }

    public static String stderrCommand(String nonce) {
        return "cat " + path(nonce) + ".stderr";
    }

    public static String cleanupCommand(String nonce) {
        String path = path(nonce);
        return "rm -f " + path + ".trace " + path + ".pid " + path + ".stderr";
    }
}
