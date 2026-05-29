
package erudition_program;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;

public final class ModelPicker {
    private static final long GB = 1024L * 1024L * 1024L;

    public static final java.util.Map<String, java.util.List<String>> MODEL_FAMILIES = new java.util.LinkedHashMap<>();
    static {
        MODEL_FAMILIES.put("Gemma 3", java.util.List.of("gemma3n:e2b", "gemma3n:e4b"));
        MODEL_FAMILIES.put("Qwen 3", java.util.List.of("qwen3:4b", "qwen3:8b"));
        MODEL_FAMILIES.put("DeepSeek R1", java.util.List.of("deepseek-r1:8b", "deepseek-r1:14b"));
    }

    public static double getEstimatedVramGb(String modelName) {
        if (modelName.contains("14b") || modelName.contains("12b")) return 10.0;
        if (modelName.contains("8b") || modelName.contains("7b")) return 6.0;
        if (modelName.contains("4b")) return 4.0;
        if (modelName.contains("2b")) return 2.5;
        return 8.0; // Default fallback
    }

    private ModelPicker() {
    }

    public static String pickBestModel(){return pickBestModel(0);}
    public static String pickBestModel(float thres) {
        thres = (Float.isNaN(thres)) ? 0 : thres;

        long[] m = GpuMemoryNative.queryVideoMemory();
        long localBudget = m[0];
        long localUsage = m[1];

        if (localBudget <= 0) {
            return "qwen3:4b";
        }

        long headroom = Math.max(0L, localBudget - Math.max(0L, localUsage));
        double safeGb = (headroom / (double) GB) * 0.85;

        if (safeGb < 4.0) return "gemma3n:e2b";
        if (safeGb < 6.0) return "gemma3n:e4b";
        if (safeGb < 10.0) return "qwen3:4b";
        if (safeGb < 16.0) return "qwen3:8b";
        if (safeGb < 28.0) return "deepseek-r1:8b";
        return "deepseek-r1:14b";
    }

    public enum CapacityLevel {
        SAFE("Optimal performance expected."),
        WARNING("Model size is close to maximum VRAM limit. Responses may be slow."),
        DANGER("Model exceeds available VRAM. Out-of-memory errors or severe lag likely.");

        private final String message;
        CapacityLevel(String message) { this.message = message; }
        public String getMessage() { return message; }
    }

    public static CapacityLevel evaluateModelCapacity(String modelName) {
        long[] m = GpuMemoryNative.queryVideoMemory();
        long localBudget = m[0];
        long localUsage = m[1];

        if (localBudget <= 0) return CapacityLevel.SAFE;

        long headroom = Math.max(0L, localBudget - Math.max(0L, localUsage));
        double safeGb = headroom / (double) GB;

        double requiredGb = 4.0; 
        if (modelName.contains("70b") || modelName.contains("72b")) requiredGb = 40.0;
        else if (modelName.contains("32b")) requiredGb = 20.0;
        else if (modelName.contains("14b") || modelName.contains("12b")) requiredGb = 10.0;
        else if (modelName.contains("8b") || modelName.contains("7b")) requiredGb = 6.0;

        if (safeGb > requiredGb * 1.2) return CapacityLevel.SAFE;
        if (safeGb >= requiredGb * 0.9) return CapacityLevel.WARNING;
        return CapacityLevel.DANGER;
    }

    public static String memorySummary() {
        long[] m = GpuMemoryNative.queryVideoMemory();
        long localBudget = m[0];
        long localUsage = m[1];
        long localAvail = m[2];

        if (localBudget <= 0) {
            return "GPU budget unavailable. Using fallback model.";
        }

        double budgetGb = localBudget / (double) GB;
        double usageGb = Math.max(0L, localUsage) / (double) GB;
        double availGb = Math.max(0L, localAvail) / (double) GB;

        return String.format("GPU budget: %.2f GB | usage: %.2f GB | reservation headroom: %.2f GB | suggested: %s",
                budgetGb, usageGb, availGb, pickBestModel());
    }
}