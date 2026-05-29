// MainApp.java
// for future -- deep java library for developing ai tools @https://djl.ai/

package erudition_program;
import javafx.application.Application;
import javafx.application.Platform;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.geometry.Pos;
import javafx.scene.Scene;
import javafx.scene.control.Button;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Label;
import javafx.scene.control.ProgressIndicator;
import javafx.scene.control.TextArea;
import javafx.scene.control.TextField;
import javafx.scene.layout.BorderPane;
import javafx.scene.layout.HBox;
import javafx.scene.layout.Priority;
import javafx.scene.layout.VBox;
import javafx.stage.Stage;

public class MainApp extends Application {
    private final OllamaClient ollamaClient = new OllamaClient();

    private static final String SYSTEM_PROMPT =
            "You are an educational assistant for coding, research, and teaching. " +
            "Prioritize correctness, practical explanation, and learning support.";

    @Override
    public void start(Stage stage) {
        Task<Void> bootstrapTask = new Task<>() {
            @Override
            protected Void call() {
                OllamaBootstrap.ensureReady();
                return null;
            }
        };

        Stage loadingStage = new Stage();
        ProgressIndicator pi = new ProgressIndicator();
        Scene loadingScene = new Scene(new VBox(pi), 120, 120);
        loadingStage.setScene(loadingScene);
        loadingStage.setTitle("Initializing...");
        loadingStage.show();

        bootstrapTask.setOnSucceeded(e -> {
            loadingStage.close();
            initUI(stage);
        });

        bootstrapTask.setOnFailed(e -> {
            loadingStage.close();
            Throwable ex = bootstrapTask.getException();
            throw new RuntimeException("Startup failed: " + ex.getMessage(), ex);
        });

        new Thread(bootstrapTask).start();
        
    }

    private void initUI(Stage stage) {
        ui.ChatLayout rootLayout = new ui.ChatLayout(ollamaClient, SYSTEM_PROMPT);
        Scene scene = new Scene(rootLayout, 1200, 800);
        scene.getStylesheets().add(getClass().getResource("/styles.css").toExternalForm());

        stage.setTitle("EduTool");
        stage.setScene(scene);
        stage.setMinWidth(900);
        stage.setMinHeight(600);
        stage.show();
    }

    private static void append(TextArea area, String text) {
        area.appendText(text);
        area.positionCaret(area.getLength());
    }

    public static void main(String[] args) {
        launch(args);
    }
}