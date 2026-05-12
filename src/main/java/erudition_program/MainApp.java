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

    private void initUI(Stage stage){
        TextArea transcript = new TextArea();
        transcript.setEditable(false);
        transcript.setWrapText(true);

        TextArea prompt = new TextArea();
        prompt.setPromptText("Enter a prompt...");
        prompt.setWrapText(true);
        prompt.setPrefRowCount(4);

        ComboBox<String> modelBox = new ComboBox<>(ModelPicker.supportedModels());
        modelBox.setPrefWidth(220);
        modelBox.setValue(ModelPicker.pickBestModel());

        Label memoryLabel = new Label(ModelPicker.memorySummary());
        memoryLabel.getStyleClass().add("muted");

        Label statusLabel = new Label();
        statusLabel.getStyleClass().add("muted");

        ProgressIndicator spinner = new ProgressIndicator();
        spinner.setVisible(false);
        spinner.setPrefSize(18, 18);

        Button sendButton = new Button("Send");
        sendButton.setDefaultButton(true);

        Runnable refreshConnectionStatus = () -> {
            statusLabel.setText(ollamaClient.isServerAvailable()
                    ? "Ollama reachable on localhost:11434"
                    : "Ollama not reachable. Start the Ollama app/service first.");
        };

        refreshConnectionStatus.run();

        sendButton.setOnAction(event -> {
            String userPrompt = prompt.getText().trim();
            String selectedModel = modelBox.getValue();

            if (userPrompt.isEmpty()) {
                return;
            }

            append(transcript, "\nYou [" + selectedModel + "]:\n" + userPrompt + "\n");
            prompt.clear();

            sendButton.setDisable(true);
            spinner.setVisible(true);
            statusLabel.setText("Running...");

            Task<String> task = new Task<>() {
                @Override
                protected String call() throws Exception {
                    try { return ollamaClient.chat(selectedModel, userPrompt, SYSTEM_PROMPT); }
                    catch (Exception e){
                        String runtimeModel = ModelPicker.pickBestModel();
                        return ollamaClient.chat(runtimeModel, userPrompt, SYSTEM_PROMPT);
                    }
                }
            };

            task.setOnSucceeded(workerStateEvent -> {
                append(transcript, "\nAssistant:\n" + task.getValue() + "\n");
                statusLabel.setText("Done.");
                sendButton.setDisable(false);
                spinner.setVisible(false);
                refreshConnectionStatus.run();
            });

            task.setOnFailed(workerStateEvent -> {
                Throwable ex = task.getException();
                append(transcript, "\nError:\n" + (ex == null ? "Unknown error" : ex.getMessage()) + "\n");
                statusLabel.setText("Request failed.");
                sendButton.setDisable(false);
                spinner.setVisible(false);
                refreshConnectionStatus.run();
            });

            Thread worker = new Thread(task, "ollama-request");
            worker.setDaemon(true);
            worker.start();
        });

        HBox topRow = new HBox(10, new Label("Model"), modelBox, spinner);
        topRow.setAlignment(Pos.CENTER_LEFT);

        HBox.setHgrow(modelBox, Priority.NEVER);

        HBox actionRow = new HBox(10, sendButton, statusLabel);
        actionRow.setAlignment(Pos.CENTER_LEFT);

        VBox bottom = new VBox(10, prompt, actionRow);
        bottom.setPadding(new Insets(12));
        VBox.setVgrow(prompt, Priority.ALWAYS);

        VBox top = new VBox(8, topRow, memoryLabel);
        top.setPadding(new Insets(12));

        BorderPane root = new BorderPane();
        root.setTop(top);
        root.setCenter(transcript);
        root.setBottom(bottom);

        Scene scene = new Scene(root, 980, 720);
        scene.getStylesheets().add(getClass().getResource("/styles.css").toExternalForm());

        stage.setTitle("EduTool");
        stage.setScene(scene);
        stage.show();

        Platform.runLater(prompt::requestFocus);
    }

    private static void append(TextArea area, String text) {
        area.appendText(text);
        area.positionCaret(area.getLength());
    }

    public static void main(String[] args) {
        launch(args);
    }
}