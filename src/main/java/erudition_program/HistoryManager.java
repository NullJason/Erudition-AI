package erudition_program;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

public final class HistoryManager {
    private static final Path HISTORY_FILE = Paths.get(System.getProperty("user.home"), ".edutool_history.txt");

    public static void saveMessage(String sender, String message) {
        try {
            String entry = String.format("[%s]\n%s\n---\n", sender, message);
            Files.writeString(HISTORY_FILE, entry, java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
        } catch (IOException ignored) {}
    }

    public static List<String[]> loadHistory() {
        List<String[]> history = new ArrayList<>();
        if (!Files.exists(HISTORY_FILE)) return history;

        try {
            String content = Files.readString(HISTORY_FILE);
            String[] entries = content.split("---\n");
            for (String entry : entries) {
                if (entry.isBlank()) continue;
                int newlineIdx = entry.indexOf('\n');
                if (newlineIdx > 0) {
                    String header = entry.substring(0, newlineIdx).replaceAll("[\\[\\]]", "").trim();
                    String msg = entry.substring(newlineIdx + 1).trim();
                    history.add(new String[]{header, msg});
                }
            }
        } catch (IOException ignored) {}
        return history;
    }

    public static void clearHistory() {
        try { Files.deleteIfExists(HISTORY_FILE); } catch (IOException ignored) {}
    }
}