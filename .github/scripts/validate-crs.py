"""Validates rendered KEDA, Gateway API, VPA and Prometheus Operator objects against their CRD schemas."""
import glob
import sys

import jsonschema
import yaml

schemas = {}
crd_files = (
    glob.glob("/tmp/keda/config/crd/bases/*.yaml")
    + glob.glob("/tmp/gwapi/config/crd/standard/*.yaml")
    + glob.glob("/tmp/vpa/vertical-pod-autoscaler/deploy/vpa-v1-crd-gen.yaml")
    + glob.glob("/tmp/promop/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml")
    + glob.glob("/tmp/promop/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml")
)
for path in crd_files:
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
        # CRD schemas carry Go regexes (e.g. (?i) mid-pattern) that Python's re
        # rejects as a schema; validate the documents without checking the schema.
        errors = list(jsonschema.Draft7Validator(schemas[key]).iter_errors(doc))
        name = f"{path} {doc['kind']}/{doc['metadata']['name']}"
        if errors:
            failed = True
            for err in errors:
                print(f"INVALID {name}: {err.message} at {list(err.path)}")
        else:
            print(f"ok      {name}")
sys.exit(1 if failed else 0)
