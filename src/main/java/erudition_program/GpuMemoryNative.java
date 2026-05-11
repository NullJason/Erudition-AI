package erudition_program;

// import java.io.File;
import java.net.URISyntaxException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

public final class GpuMemoryNative {
    private static volatile boolean attemptedLoad = false;
    private static volatile boolean loaded = false;

    private GpuMemoryNative() {
    }

    public static long[] queryVideoMemory() {
        ensureLoaded();
        if (!loaded) {
            return new long[] { -1, -1, -1, -1, -1, -1 };
        }

        try {
            return queryVideoMemoryNative();
        } catch (Throwable t) {
            return new long[] { -1, -1, -1, -1, -1, -1 };
        }
    }

    private static synchronized void ensureLoaded() {
        if (attemptedLoad) {
            return;
        }
        attemptedLoad = true;

        String mapped = System.mapLibraryName("gpu_memory_native");

        for (Path candidate : candidatePaths(mapped)) {
            try {
                if (candidate != null && Files.isRegularFile(candidate)) {
                    System.load(candidate.toAbsolutePath().toString());
                    loaded = true;
                    return;
                }
            } catch (Throwable ignored) {
            }
        }
    }

    private static Path[] candidatePaths(String mapped) {
        Path codeSourceDir = codeSourceDirectory();
        Path cwd = Paths.get("").toAbsolutePath();

        String nativeDir = System.getProperty("native.dir");
        if (nativeDir != null && !nativeDir.isBlank()) {
            return new Path[] {
                    Paths.get(nativeDir).resolve(mapped),
                    codeSourceDir.resolve(mapped),
                    Paths.get("native", "build", "Release", mapped),
                    Paths.get("native", "build", "Debug", mapped),
                    cwd.resolve(mapped)
            };
        }

        return new Path[] {
                codeSourceDir.resolve(mapped),
                Paths.get("native", "build", "Release", mapped),
                Paths.get("native", "build", "Debug", mapped),
                cwd.resolve(mapped)
        };
    }

    private static Path codeSourceDirectory() {
        try {
            Path location = Paths.get(GpuMemoryNative.class.getProtectionDomain()
                    .getCodeSource()
                    .getLocation()
                    .toURI());

            if (Files.isDirectory(location)) {
                return location;
            }

            Path parent = location.getParent();
            return parent != null ? parent : location;
        } catch (URISyntaxException | NullPointerException e) {
            return Paths.get("").toAbsolutePath();
        }
    }

    private static native long[] queryVideoMemoryNative();
}