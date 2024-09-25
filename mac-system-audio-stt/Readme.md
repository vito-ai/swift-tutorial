# mac-system-audio-stt

A software that displays real-time subtitles for system audio on MacOS using streaming Speech-To-Text (STT) technology. This project is implemented as an applied example utilizing the STT API provided by ReturnZero, a company specializing in AI-powered speech recognition solutions.

## Requirements

- MacOS 13.0 or higher

## Installation

### 1. Install Xcode Command Line Tools

```bash
xcode-select --install
```

### 2. Install Swift

```bash
brew install swift
```

### 3. Install Proto and gRPC programs

```bash
brew install protobuf swift-protobuf grpc-swift
```

## Proto File Setup

### Download the Proto file

Choose one of the following methods to download Proto file into the `{root directory}/Sources/` directory:

1. Using wget:
   ```bash
   wget https://raw.github.com/vito-ai/openapi-grpc/main/protos/vito-stt-client.proto
   ```

2. Manual download:
   Visit [this GitHub link](https://github.com/vito-ai/openapi-grpc/blob/main/protos/vito-stt-client.proto) and save the file locally.

### Compile the Proto file

```bash
protoc --swift_out=. --grpc-swift_out=. vito-stt-client.proto
```

## Setting up ReturnZero Developer Account

To use this project, you need a developer account with access to ReturnZero's STT API. Follow these steps to set up your account:

1. Sign up for an account at the [ReturnZero Developers site](https://developers.rtzr.ai).
2. After signing up, go to 'MY Console' and click on 'New Registration' in the 'My Applications' section.
3. Complete the application creation process.
4. Save the CLIENT ID and CLIENT SECRET of your newly created application in a secure place.
   - Note: The CLIENT SECRET is only displayed once. If lost, you'll need to request a new one.

You'll need this information for the next step in setting up the project.

## Configuration

Create a `secret.env` file in the `{root directory}/Sources/Resources/` directory with the following format:

```
CLIENT_ID={Your ReturnZero Developer Application CLIENT ID}
CLIENT_SECRET={Your ReturnZero Developer Application CLIENT SECRET}
```

## Build and Run

To build the project:

```bash
swift build
```

To run the project:

```bash
swift run
```
