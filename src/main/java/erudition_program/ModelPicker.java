
package erudition_program;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;

public final class ModelPicker {
    private static final long GB = 1024L * 1024L * 1024L;

    private static final ObservableList<String> MODELS = FXCollections.observableArrayList(
            "gemma3n:e2b",
            "gemma3n:e4b",
            "qwen3:4b",
            "qwen3:8b",
            "deepseek-r1:8b",
            "deepseek-r1:14b"
    );

    private ModelPicker() {
    }

    public static ObservableList<String> supportedModels() {
        return FXCollections.unmodifiableObservableList(MODELS);
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