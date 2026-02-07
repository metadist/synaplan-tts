# synaplan-tts

Running your own Text-To-Speech service on a GPU server with Piper. This repo is in use with our own platform to provide speech generation services for customers.

## Setup

### Prerequisites
- Docker and Docker Compose
- Voice models (ONNX format)

### Directory Structure
```
synaplan-tts/
├── docker-compose.yml    # Docker configuration
├── README.md            # This file
├── voices/              # Voice models (gitignored)
└── data/                # Data directory
```

### Installation

1. Download a Piper voice model and place it in the `voices/` directory:
   
   Example for en_US-lessac-medium voice:
   ```bash
   cd voices/
   # Download the ONNX model file
   curl -L -o en_US-lessac-medium.onnx \
     "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
   
   # Download the config file
   curl -L -o en_US-lessac-medium.onnx.json \
     "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
   ```
   
   Browse all available voices at: https://huggingface.co/rhasspy/piper-voices/tree/main

2. Update `docker-compose.yml` to use your voice model:
   ```yaml
   command: --voice en_US-lessac-medium
   ```

3. Start the service:
   ```bash
   docker-compose up -d
   ```

4. The TTS service will be available at `http://127.0.0.1:10200`

### Configuration

The service is configured to:
- Bind to localhost only (127.0.0.1:10200)
- Mount the `voices/` directory to the container
- Restart automatically unless stopped manually
- Use the container name: `synaplan-piper-tts`

### Voice Models

Voice models are kept out of git to keep the repository size small. Download the models you need from the [Piper voices repository](https://huggingface.co/rhasspy/piper-voices/tree/main).

### Usage

Once running, you can use the Wyoming protocol to generate speech. The service runs on port 10200.
