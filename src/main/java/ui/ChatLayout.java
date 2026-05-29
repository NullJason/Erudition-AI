package ui;

import erudition_program.HistoryManager;
import erudition_program.ModelPicker;
import erudition_program.OllamaClient;
import javafx.application.Platform;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.geometry.Pos;
import javafx.scene.control.*;
import javafx.scene.input.Clipboard;
import javafx.scene.input.KeyCode;
import javafx.scene.input.KeyEvent;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.nio.file.Files;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class ChatLayout extends BorderPane {

    private final OllamaClient ollamaClient;
    private final String systemPrompt;
    private Task<String> currentTask;
    private String activeModel;

    private VBox messageContainer;
    private ScrollPane scrollPane;
    private TextArea inputArea;
    private Button sendButton;
    private Button cancelButton;
    private MenuButton modelSelector;
    private Label systemWarningLabel;
    private HBox thinkingIndicator;
    private VBox installOverlay;

    public ChatLayout(OllamaClient ollamaClient, String systemPrompt) {
        this.ollamaClient = ollamaClient;
        this.systemPrompt = systemPrompt;
        this.activeModel = ModelPicker.pickBestModel();
        buildUI();
        setupEventHandlers();
        loadHistory();
        checkHardwareAndInstallationStatus();
    }

    private void buildUI() {
        VBox sidebar = new VBox(15);
        sidebar.getStyleClass().add("sidebar");
        sidebar.setPrefWidth(250);
        Label historyLabel = new Label("EduTool Actions");
        historyLabel.getStyleClass().add("sidebar-header");

        Button clearBtn = new Button("Clear Chat");
        clearBtn.setMaxWidth(Double.MAX_VALUE);
        clearBtn.setOnAction(e -> clearChat());

        Button exportBtn = new Button("Export to Markdown");
        exportBtn.setMaxWidth(Double.MAX_VALUE);
        exportBtn.setOnAction(e -> exportChat());

        sidebar.getChildren().addAll(historyLabel, clearBtn, exportBtn);
        this.setLeft(sidebar);

        HBox topBar = new HBox(15);
        topBar.getStyleClass().add("top-bar");
        topBar.setAlignment(Pos.CENTER_LEFT);

        modelSelector = new MenuButton(activeModel);
        ModelPicker.MODEL_FAMILIES.forEach((family, models) -> {
            Menu familyMenu = new Menu(family);
            for (String mod : models) {
                MenuItem item = new MenuItem(mod);
                item.setOnAction(e -> {
                    activeModel = mod;
                    modelSelector.setText(mod);
                    checkHardwareAndInstallationStatus();
                });
                familyMenu.getItems().add(item);
            }
            modelSelector.getItems().add(familyMenu);
        });

        systemWarningLabel = new Label();
        systemWarningLabel.setVisible(false);
        systemWarningLabel.setManaged(false);
        topBar.getChildren().addAll(new Label("Active Model:"), modelSelector, systemWarningLabel);

        messageContainer = new VBox(15);
        messageContainer.getStyleClass().add("chat-container");
        messageContainer.setPadding(new Insets(20));

        scrollPane = new ScrollPane(messageContainer);
        scrollPane.setFitToWidth(true);
        scrollPane.getStyleClass().add("chat-scroll");

        installOverlay = buildInstallOverlay();

        StackPane centerStack = new StackPane(scrollPane, installOverlay);

        inputArea = new TextArea();
        inputArea.setPromptText("Message EduTool... Use <terminal>cmd</terminal> to run local commands.");
        inputArea.setWrapText(true);
        inputArea.setPrefRowCount(3);
        inputArea.getStyleClass().add("input-area");

        sendButton = new Button("Send");
        sendButton.getStyleClass().addAll("action-button", "send-button");

        cancelButton = new Button("Cancel");
        cancelButton.getStyleClass().addAll("action-button", "cancel-button");
        cancelButton.setVisible(false);
        cancelButton.setManaged(false);

        HBox buttonBox = new HBox(10, cancelButton, sendButton);
        buttonBox.setAlignment(Pos.BOTTOM_RIGHT);

        VBox inputContainer = new VBox(10, inputArea, buttonBox);
        inputContainer.getStyleClass().add("input-container");
        inputContainer.setPadding(new Insets(15));

        BorderPane centerLayout = new BorderPane();
        centerLayout.setTop(topBar);
        centerLayout.setCenter(centerStack);
        centerLayout.setBottom(inputContainer);
        this.setCenter(centerLayout);

        ProgressIndicator spinner = new ProgressIndicator();
        spinner.setPrefSize(20, 20);
        Label thinkingLabel = new Label("Model is processing...");
        thinkingLabel.getStyleClass().add("thinking-text");
        thinkingIndicator = new HBox(10, spinner, thinkingLabel);
        thinkingIndicator.setAlignment(Pos.CENTER_LEFT);
        thinkingIndicator.getStyleClass().add("thinking-indicator");
    }

    private VBox buildInstallOverlay() {
        VBox overlay = new VBox(15);
        overlay.setAlignment(Pos.CENTER);
        overlay.getStyleClass().add("install-overlay");
        overlay.setVisible(false);

        Label title = new Label("Model Not Installed");
        title.setStyle("-fx-font-size: 20px; -fx-font-weight: bold;");

        Label specsLabel = new Label();
        specsLabel.setId("specsLabel");

        HBox btnBox = new HBox(15);
        btnBox.setAlignment(Pos.CENTER);

        Button installBtn = new Button("Install via Ollama");
        installBtn.getStyleClass().addAll("action-button", "send-button");
        installBtn.setOnAction(e -> {
            installBtn.setDisable(true);
            installBtn.setText("Installing...");
            runInstallTask(installBtn);
        });

        Button capsBtn = new Button("View Capabilities");
        capsBtn.setOnAction(e -> {
            Alert alert = new Alert(Alert.AlertType.INFORMATION);
            alert.setTitle("Model Capabilities");
            alert.setHeaderText(activeModel);
            TextArea area = new TextArea(ollamaClient.getModelCapabilities(activeModel));
            area.setEditable(false);
            alert.getDialogPane().setContent(area);
            alert.showAndWait();
        });

        btnBox.getChildren().addAll(installBtn, capsBtn);
        overlay.getChildren().addAll(title, specsLabel, btnBox);
        return overlay;
    }

    private void setupEventHandlers() {
        inputArea.addEventFilter(KeyEvent.KEY_PRESSED, event -> {
            if (event.isShortcutDown() && event.getCode() == KeyCode.V) {
                Clipboard clipboard = Clipboard.getSystemClipboard();
                if (clipboard.hasString()) {
                    String content = clipboard.getString();
                    if (content.contains("\n")) {
                        event.consume();
                        Alert alert = new Alert(Alert.AlertType.CONFIRMATION);
                        alert.setTitle("Multiline Paste Warning");
                        alert.setHeaderText("Potential Command Execution");
                        String preview = content.length() > 100 ? content.substring(0, 100) + "..." : content;
                        alert.setContentText("You are about to paste text that contains multiple lines. If you paste this text, it may result in the unexpected execution of commands. Do you wish to continue?\n\nClipboard contents (preview):\n" + preview);
                        alert.showAndWait().ifPresent(type -> {
                            if (type == ButtonType.OK) {
                                inputArea.insertText(inputArea.getCaretPosition(), content);
                            }
                        });
                    }
                }
            }
        });

        inputArea.setOnKeyPressed(event -> {
            if (event.getCode() == KeyCode.ENTER) {
                if (event.isShiftDown()) inputArea.appendText("\n");
                else { event.consume(); submitRequest(); }
            }
        });

        sendButton.setOnAction(e -> submitRequest());
        cancelButton.setOnAction(e -> {
            if (currentTask != null && currentTask.isRunning()) {
                currentTask.cancel(true);
                removeThinkingIndicator();
                appendMessage("System", "Request cancelled by user.", "system-message", false);
                resetInputState();
            }
        });
    }

    private void checkHardwareAndInstallationStatus() {
        if (activeModel == null) return;
        
        boolean downloaded = ollamaClient.isModelDownloaded(activeModel);
        if (!downloaded) {
            scrollPane.setVisible(false);
            installOverlay.setVisible(true);
            inputArea.setDisable(true);
            sendButton.setDisable(true);
            
            Label specs = (Label) installOverlay.lookup("#specsLabel");
            specs.setText(String.format("Model: %s\nEstimated VRAM required: %.1f GB", activeModel, ModelPicker.getEstimatedVramGb(activeModel)));
            
            systemWarningLabel.setVisible(false);
            return;
        }

        scrollPane.setVisible(true);
        installOverlay.setVisible(false);
        inputArea.setDisable(false);
        sendButton.setDisable(false);

        ModelPicker.CapacityLevel level = ModelPicker.evaluateModelCapacity(activeModel);
        systemWarningLabel.getStyleClass().removeAll("warning-banner", "danger-banner");
        
        if (level == ModelPicker.CapacityLevel.SAFE) {
            systemWarningLabel.setVisible(false);
            systemWarningLabel.setManaged(false);
        } else {
            systemWarningLabel.setText(level.getMessage());
            systemWarningLabel.setVisible(true);
            systemWarningLabel.setManaged(true);
            systemWarningLabel.getStyleClass().add(level == ModelPicker.CapacityLevel.WARNING ? "warning-banner" : "danger-banner");
        }
    }

    private void runInstallTask(Button installBtn) {
        Task<Void> installTask = new Task<>() {
            @Override
            protected Void call() throws Exception {
                Process p = new ProcessBuilder("ollama", "pull", activeModel).redirectErrorStream(true).start();
                p.waitFor();
                return null;
            }
        };
        installTask.setOnSucceeded(e -> {
            installBtn.setText("Install via Ollama");
            installBtn.setDisable(false);
            checkHardwareAndInstallationStatus();
        });
        installTask.setOnFailed(e -> {
            installBtn.setText("Install via Ollama");
            installBtn.setDisable(false);
            appendMessage("System", "Failed to pull model.", "error-message", false);
        });
        new Thread(installTask).start();
    }

    private void submitRequest() {
        String prompt = inputArea.getText().trim();
        if (prompt.isEmpty()) return;

        appendMessage("User", prompt, "user-message", true);
        inputArea.clear();

        sendButton.setDisable(true);
        cancelButton.setVisible(true);
        cancelButton.setManaged(true);
        showThinkingIndicator();

        currentTask = new Task<>() {
            @Override
            protected String call() throws Exception {
                String finalPrompt = executeTerminalTags(prompt);
                return ollamaClient.chat(activeModel, finalPrompt, systemPrompt);
            }
        };

        currentTask.setOnSucceeded(e -> {
            removeThinkingIndicator();
            appendMessage("Assistant", currentTask.getValue(), "ai-message", true);
            resetInputState();
        });

        currentTask.setOnFailed(e -> {
            removeThinkingIndicator();
            Throwable ex = currentTask.getException();
            if (!(ex instanceof InterruptedException)) {
                appendMessage("System Error", ex.getMessage(), "error-message", false);
            }
            resetInputState();
        });

        Thread executionThread = new Thread(currentTask);
        executionThread.setDaemon(true);
        executionThread.start();
    }

    private String executeTerminalTags(String prompt) {
        Pattern pattern = Pattern.compile("<terminal>(.*?)</terminal>", Pattern.DOTALL);
        Matcher matcher = pattern.matcher(prompt);
        StringBuffer sb = new StringBuffer();
        
        while (matcher.find()) {
            String cmd = matcher.group(1).trim();
            String output = runLocalCommand(cmd);
            matcher.appendReplacement(sb, "Terminal Output for [" + cmd + "]:\n" + Matcher.quoteReplacement(output));
        }
        matcher.appendTail(sb);
        return sb.toString();
    }

    private String runLocalCommand(String command) {
        try {
            ProcessBuilder pb = new ProcessBuilder("cmd.exe", "/c", command);
            pb.redirectErrorStream(true);
            Process p = pb.start();
            BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream()));
            StringBuilder out = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) out.append(line).append("\n");
            p.waitFor();
            return out.toString().isBlank() ? "(No output)" : out.toString();
        } catch (Exception e) {
            return "Command execution failed: " + e.getMessage();
        }
    }

    private void appendMessage(String sender, String text, String cssClass, boolean persist) {
        VBox messageBox = new VBox(5);
        messageBox.getStyleClass().addAll("message-wrapper", cssClass);

        HBox header = new HBox(10);
        header.setAlignment(Pos.CENTER_LEFT);
        Label senderLabel = new Label(sender);
        senderLabel.getStyleClass().add("message-sender");
        header.getChildren().add(senderLabel);

        if ("Assistant".equals(sender)) {
            Button copyBtn = new Button("Copy");
            copyBtn.setStyle("-fx-font-size: 10px; -fx-padding: 2 6;");
            copyBtn.setOnAction(e -> {
                Clipboard clipboard = Clipboard.getSystemClipboard();
                javafx.scene.input.ClipboardContent content = new javafx.scene.input.ClipboardContent();
                content.putString(text);
                clipboard.setContent(content);
            });
            header.getChildren().add(copyBtn);
        }

        Label textLabel = new Label(text);
        textLabel.setWrapText(true);
        textLabel.getStyleClass().add("message-body");

        messageBox.getChildren().addAll(header, textLabel);
        messageContainer.getChildren().add(messageBox);
        scrollToBottom();

        if (persist) HistoryManager.saveMessage(sender, text);
    }

    private void loadHistory() {
        List<String[]> history = HistoryManager.loadHistory();
        for (String[] entry : history) {
            String role = entry[0];
            String cssClass = role.equals("User") ? "user-message" : role.equals("Assistant") ? "ai-message" : "system-message";
            appendMessage(role, entry[1], cssClass, false);
        }
    }

    private void clearChat() {
        messageContainer.getChildren().clear();
        HistoryManager.clearHistory();
    }

    private void exportChat() {
        FileChooser fileChooser = new FileChooser();
        fileChooser.setTitle("Export Chat");
        fileChooser.getExtensionFilters().add(new FileChooser.ExtensionFilter("Markdown Files", "*.md"));
        File file = fileChooser.showSaveDialog(this.getScene().getWindow());
        if (file != null) {
            try {
                StringBuilder md = new StringBuilder("# Chat Export\n\n");
                for (String[] entry : HistoryManager.loadHistory()) {
                    md.append("**").append(entry[0]).append("**:\n").append(entry[1]).append("\n\n---\n\n");
                }
                Files.writeString(file.toPath(), md.toString());
            } catch (Exception ignored) {}
        }
    }

    private void showThinkingIndicator() {
        if (!messageContainer.getChildren().contains(thinkingIndicator)) {
            messageContainer.getChildren().add(thinkingIndicator);
            scrollToBottom();
        }
    }

    private void removeThinkingIndicator() {
        messageContainer.getChildren().remove(thinkingIndicator);
    }

    private void resetInputState() {
        sendButton.setDisable(false);
        cancelButton.setVisible(false);
        cancelButton.setManaged(false);
        Platform.runLater(inputArea::requestFocus);
    }

    private void scrollToBottom() {
        Platform.runLater(() -> scrollPane.setVvalue(1.0));
    }
}