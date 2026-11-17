"""CPU-only OpenAI-style endpoint for the demo documentation embeddings."""

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

from fastembed import TextEmbedding
from fastembed.common.model_description import ModelSource, PoolingType


MODEL = "intfloat/multilingual-e5-small"
DIMENSIONS = 384


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8031)
    parser.add_argument("--cache-dir")
    args = parser.parse_args()
    if MODEL not in {entry["model"] for entry in TextEmbedding.list_supported_models()}:
        TextEmbedding.add_custom_model(
            model=MODEL, pooling=PoolingType.MEAN, normalization=True, dim=DIMENSIONS,
            sources=ModelSource(hf=MODEL), model_file="onnx/model.onnx",
        )
    encoder = TextEmbedding(model_name=MODEL, threads=2, cache_dir=args.cache_dir)

    class Handler(BaseHTTPRequestHandler):
        def reply(self, status, body):
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_POST(self):
            if self.path != "/v1/embeddings":
                return self.reply(404, {"error": "Unknown endpoint"})
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 524288:
                    raise ValueError
                payload = json.loads(self.rfile.read(length))
                inputs = payload["input"]
                if isinstance(inputs, str):
                    inputs = [inputs]
                if (payload["model"] != MODEL or not isinstance(inputs, list)
                        or not 1 <= len(inputs) <= 24
                        or not all(isinstance(value, str) and 1 <= len(value) <= 16000
                                   for value in inputs)):
                    raise ValueError
            except (ValueError, KeyError, TypeError):
                return self.reply(400, {"error": "Invalid model or input"})
            vectors = encoder.embed(inputs, batch_size=8)
            self.reply(200, {"model": MODEL, "data": [
                {"index": index, "embedding": vector.tolist()}
                for index, vector in enumerate(vectors)
            ]})

    with HTTPServer((args.host, args.port), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
