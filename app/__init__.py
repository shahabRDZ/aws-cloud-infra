from flask import Flask, jsonify


def create_app():
    app = Flask(__name__)

    @app.route("/health")
    def health():
        return jsonify({"status": "healthy"})

    @app.route("/")
    def index():
        return jsonify({"service": "myapp", "version": "1.0.0"})

    return app
