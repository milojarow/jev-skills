# Images and Box: experimental SDK/API path

Read this for image judgments or locating a target. The official documentation
snapshot dated 2026-11-17 calls images and Box **Dreamer-ready**, not production
ready. Treat them as prototype capabilities whose contract and accuracy may
change. Use only images within the task's authorized data scope.

## Choose the input path

The bundled CLI supports text/structured-text Choice, Noul and Score. It has no
`box`, `--assets`, image-header or multipart interface. Do not feed an image to
`--state-file`, put base64 in a text-only state and expect vision, or invent CLI
flags. Use the application's existing official SDK or HTTP client for this path.
Reading the skill does not require installing an SDK or making an API call.

Send `TypeSafe-Danger-Zone-Images: true` on each request containing an image or a
Box question. Images can occur in `state`, `instructions` and `criteria`. The
snapshot documents images for Jev 1.13 and 1.14; Box requires Jev 1.14. Select a
model with the needed capability and inspect the resolved model in the response.
An SDK example using `jev-preview` does not make that moving alias a requirement
for Box; verify the installed SDK and the model contract.

The raw API lists image assets once, each under a unique reference. Supply either
base64 with a format or a multipart file part. The SDK can construct these assets
for you. A URL or filesystem path sent as ordinary text is not an uploaded image.

## Locate and separately check presence

A Box always returns four edges, even when the target is absent. Ask a companion
Noul in the **same request**, then let code ignore the box when presence is not
established. No universal Box-confidence threshold is documented; do not copy the
text skill's provisional 0.6 floor as a calibrated vision policy. Missing or null
confidence from an SDK also needs explicit handling.

This Python fragment constructs a raw API body from an authorized, prepared PNG.
It does not send the request, store credentials or perform an application action:

```python
from base64 import b64encode
from pathlib import Path
from uuid import uuid4

image_ref = uuid4().hex
payload = {
    "model": "jev-1.14.0",
    "state": {"photo": image_ref},
    "assets": {
        image_ref: {
            "type": "image",
            "format": "png",
            "data_base64": b64encode(Path("example.png").read_bytes()).decode("ascii"),
        }
    },
    "questions": {
        "present": {"type": "noul", "instructions": "Is there a coffee mug in `photo`?"},
        "region": {"type": "box", "instructions": "The coffee mug nearest the sink in `photo`."},
    },
}
extra_headers = {"TypeSafe-Danger-Zone-Images": "true"}
```

Use the existing client for authentication, transport and response validation.
Test presence on labeled present/absent images and localization against known
regions, using representative preprocessing. Text-only controls do not validate
an image workload. For this example, also distinguish multiple mugs; a Box is one
target per question, not a count or a list of detections.

The answer has `box.top`, `bottom`, `left`, `right` in `[0, 1]`, relative to the
input image, and `confidence`. Validate finite numbers and ordered edges in code.
Convert x edges using image width and y edges using image height. For a crop, add
its origin and scale back to the original coordinates; preserve the preprocessing
transform if orientation or dimensions changed. A returned rectangle does not
establish presence, an exact reading of text, or permission to act.

## Prepare assets and count expansion

Limits in the 2026-11-17 snapshot:

| Property | Documented limit |
| --- | --- |
| Image format | Still PNG or JPEG; animated PNG is rejected |
| Image file | 16 MiB after base64 decoding |
| Each side | 280–1568 pixels, inclusive |
| Pixel area | 78,400–2,458,624 pixels |
| Request body | 32 MiB, including JSON/base64 or multipart framing |
| Processed distinct images | 32 MiB combined |
| Expanded request | 32 MiB after each asset reference is replaced |

Rotate the actual pixels upright: the API strips metadata and does not apply EXIF
orientation. Resize or pad before sending; the service rejects out-of-range
dimensions rather than silently fixing them. Other formats and video require
appropriate preprocessing; the API does not natively accept audio/video streams.

References match plain text, even inside longer strings. Prefer collision-resistant
references such as UUIDs. Object keys are not replaced. Every asset must be used,
and each occurrence expands the model input again even though the file uploads
once. Put an image shared by many questions in state once instead of repeating
its reference in every question. Re-encoding can enlarge images; small uploads
alone do not prove that the processed or expanded request fits.

For raw JSON, use standard padded base64 without a `data:` prefix or whitespace.
For multipart, match each asset's `part` to its file part; the request object goes
in the JSON part named `request`. A rejected image rejects the whole request;
handle validation errors rather than treating them as absent targets.

Sources: [Images](https://docs.typesafe.ai/images.md),
[Box](https://docs.typesafe.ai/primitives/box.md),
[Models](https://docs.typesafe.ai/models.md),
[Python SDK](https://docs.typesafe.ai/sdk/python.md) and
[JavaScript SDK](https://docs.typesafe.ai/sdk/javascript.md).
