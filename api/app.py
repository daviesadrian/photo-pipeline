import os

from flask import Flask, jsonify
from google.cloud import firestore

app = Flask(__name__)

PROJECT_ID = os.environ.get("GOOGLE_CLOUD_PROJECT", "cloud-portfolio-789")
db = firestore.Client(project=PROJECT_ID)
images_collection = db.collection("images")


@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


@app.route("/images", methods=["GET"])
def list_images():
    docs = images_collection.stream()
    results = [{"id": doc.id, **doc.to_dict()} for doc in docs]
    return jsonify(results)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
