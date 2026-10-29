"""Validates rendered KEDA and Gateway API objects against their CRD schemas."""
import glob
import sys

import jsonschema
import yaml

schemas = {}
for path in glob.glob("/tmp/keda/config/crd/bases/*.yaml") + glob.glob("/tmp/gwapi/config/crd/standard/*.yaml"):
    for doc in yaml.safe_load_all(open(path)):
        if not doc or doc.get("kind") != "CustomResourceDefinition":
            continue
        group, kind = doc["spec"]["group"], doc["spec"]["names"]["kind"]
        for version in doc["spec"]["versions"]:
            schemas[(f"{group}/{version['name']}", kind)] = version["schema"]["openAPIV3Schema"]

failed = False
for path in sys.argv[1:]:
    for doc in yaml.safe_load_all(open(path)):
        if not doc:
            continue
        key = (doc["apiVersion"], doc["kind"])
        if key not in schemas:
            continue
        try:
            jsonschema.validate(doc, schemas[key])
            print(f"ok      {path} {doc['kind']}/{doc['metadata']['name']}")
        except jsonschema.ValidationError as err:
            failed = True
            print(f"INVALID {path} {doc['kind']}/{doc['metadata']['name']}: {err.message} at {list(err.path)}")
sys.exit(1 if failed else 0)
