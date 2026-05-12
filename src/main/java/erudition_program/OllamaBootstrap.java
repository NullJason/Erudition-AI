
package erudition_program;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;

public final class OllamaBootstrap {

    private OllamaBootstrap() {}

    public static void ensureReady() {
        try {
            if (!isOllamaRunning()) {
                installIfMissing();
                startOllama();
                waitForServer();
            }

            String model = ModelPicker.pickBestModel();
            ensureModelPulled(model);

        } catch (Exception e) {
            throw new RuntimeException("Ollama bootstrap failed: " + e.getMessage(), e);
        }
    }

    private static boolean isOllamaRunning() {
        try {
            HttpURLConnection conn = (HttpURLConnection)
                    URI.create("http://127.0.0.1:11434/api/tags").toURL().openConnection();
            conn.setConnectTimeout(1500);
            conn.setReadTimeout(1500);
            conn.setRequestMethod("GET");
            return conn.getResponseCode() == 200;
        } catch (Exception e) {
            return false;
        }
    }

    private static void installIfMissing() {
        if (commandWorks("ollama", "--version")) return;

        run(new String[]{
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-Command",
                "irm https://ollama.com/install.ps1 | iex"
        });
    }

    private static void startOllama() {
        try {
            new ProcessBuilder("ollama", "serve")
                    .redirectErrorStream(true)
                    .start();
        } catch (Exception e) {
            throw new RuntimeException("Failed to start Ollama", e);
        }
    }

    private static void waitForServer() {
        long start = System.currentTimeMillis();
        while (System.currentTimeMillis() - start < 20000) {
            if (isOllamaRunning()) return;
            sleep(500);
        }
        throw new RuntimeException("Ollama did not start in time");
    }

    private static void ensureModelPulled(String model) {
        try {
            if (modelExists(model)) return;

            run(new String[]{"ollama", "pull", model});

        } catch (Exception e) {
            throw new RuntimeException("Model pull failed: " + model, e);
        }
    }

    private static boolean modelExists(String model) {
        try {
            Process p = new ProcessBuilder("ollama", "list")
                    .redirectErrorStream(true)
                    .start();

            BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));

            String line;
            while ((line = br.readLine()) != null) {
                if (line.startsWith(model)) return true;
            }

            p.waitFor();
            return false;

        } catch (Exception e) {
            return false;
        }
    }

    private static boolean commandWorks(String... cmd) {
        try {
            Process p = new ProcessBuilder(cmd)
                    .redirectErrorStream(true)
                    .start();
            return p.waitFor() == 0;
        } catch (Exception e) {
            return false;
        }
    }

    private static void run(String[] cmd) {
        try {
            Process p = new ProcessBuilder(cmd)
                    .inheritIO()
                    .start();

            int code = p.waitFor();
            if (code != 0) {
                throw new RuntimeException("Command failed: " + String.join(" ", cmd));
            }
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
    }
}