
package erudition_program;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class OllamaClient {
    private static final URI CHAT_URI = URI.create("http://127.0.0.1:11434/api/chat");
    private static final URI TAGS_URI = URI.create("http://127.0.0.1:11434/api/tags");
    private static final String DEFAULT_SYSTEM_PROMPT =
            "You are an educational assistant for coding, research, and teaching. " +
            "Be accurate, structured, and concise. Show reasoning only when it helps.";

    private final HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    private final ObjectMapper mapper = new ObjectMapper();

    public boolean isModelDownloaded(String model) {
        try {
            HttpRequest request = HttpRequest.newBuilder().uri(TAGS_URI).timeout(Duration.ofSeconds(3)).GET().build();
            HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            JsonNode root = mapper.readTree(response.body());
            for (JsonNode modelNode : root.path("models")) {
                if (modelNode.path("name").asText("").equals(model) || modelNode.path("name").asText("").equals(model + ":latest")) {
                    return true;
                }
            }
            return false;
        } catch (Exception e) {
            return false;
        }
    }

    public String getModelCapabilities(String model) {
        try {
            Map<String, String> body = Map.of("model", model);
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create("http://127.0.0.1:11434/api/show"))
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(body)))
                    .build();
            HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            if (response.statusCode() == 200) {
                JsonNode root = mapper.readTree(response.body());
                return root.path("details").toPrettyString() + "\nSystem:\n" + root.path("system").asText("N/A");
            }
        } catch (Exception ignored) {}
        return "Capabilities data unavailable via API. Model may require installation first.";
    }

    public boolean isServerAvailable() {
        try {
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(TAGS_URI)
                    .timeout(Duration.ofSeconds(3))
                    .GET()
                    .build();

            HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            return response.statusCode() == 200;
        } catch (Exception e) {
            return false;
        }
    }

    public String chat(String model, String userPrompt) throws IOException, InterruptedException {
        return chat(model, userPrompt, DEFAULT_SYSTEM_PROMPT);
    }

    public String chat(String model, String userPrompt, String systemPrompt) throws IOException, InterruptedException {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("model", model);
        body.put("stream", false);
        body.put("messages", List.of(
                Map.of("role", "system", "content", systemPrompt),
                Map.of("role", "user", "content", userPrompt)
        ));

        String json = mapper.writeValueAsString(body);

        HttpRequest request = HttpRequest.newBuilder()
                .uri(CHAT_URI)
                .timeout(Duration.ofSeconds(120))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(json, StandardCharsets.UTF_8))
                .build();

        HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));

        if (response.statusCode() != 200) {
            throw new IOException("Ollama HTTP " + response.statusCode() + ": " + response.body());
        }

        JsonNode root = mapper.readTree(response.body());
        JsonNode message = root.path("message");
        String content = message.path("content").asText(null);

        if (content == null || content.isBlank()) {
            throw new IOException("Empty response from Ollama.");
        }

        return content.trim();
    }
}