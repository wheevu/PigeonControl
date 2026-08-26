"""Reproduce Study 1 telemetry-only held-out evaluation.

The script intentionally reports smoke-scale results without calling them a
research conclusion. Inputs are converted Parquet runs and seed-level splits.
"""
from __future__ import annotations
import argparse, json
from pathlib import Path
import numpy as np
import torch
from pigeon_observer.data import ObserverSequenceDataset
from pigeon_observer.training import load_checkpoint
from pigeon_observer.evaluation.metrics import classification_metrics, regression_metrics, calibration_metrics

def score(root: Path, checkpoint: Path, temporal: str):
    ds = ObserverSequenceDataset(root, "test", mode="telemetry", sequence_length=8, horizon=6)
    model, meta = load_checkpoint(checkpoint, map_location="cpu")
    model.eval(); rows=[]
    with torch.no_grad():
        for item in ds:
            batch={"telemetry": item["telemetry"].unsqueeze(0), "targets": {k:v.unsqueeze(0) for k,v in item["targets"].items()}}
            out=model(batch)
            rows.append({"seed": item["metadata"]["seed"], "panic": float(item["targets"]["panic"]),
                         "panic_prob": float(torch.sigmoid(out["panic_logits"])[0]),
                         "fear": float(item["targets"]["hidden_genome"][0]), "fear_pred": float(out["hidden_genome"][0,0]),
                         "greed": float(item["targets"]["hidden_genome"][1]), "greed_pred": float(out["hidden_genome"][0,1])})
    y=np.array([r["panic"] for r in rows]); p=np.array([r["panic_prob"] for r in rows]); yp=(p>=.5).astype(int)
    fear_metrics=regression_metrics([r["fear"] for r in rows],[r["fear_pred"] for r in rows])
    greed_metrics=regression_metrics([r["greed"] for r in rows],[r["greed_pred"] for r in rows])
    for metrics in (fear_metrics, greed_metrics):
        for key, value in list(metrics.items()):
            if not np.isfinite(value): metrics[key]=None
    result={"temporal":temporal,"checkpoint":str(checkpoint),"parameters":sum(p.numel() for p in model.parameters()),
            "n_test_windows":len(rows),"seeds":sorted(set(r["seed"] for r in rows)),
            "panic":{**classification_metrics(y,yp,p),**calibration_metrics(y,p)},
            "fear":fear_metrics,"greed":greed_metrics,
            "negative_findings":["This study has no rendered frames, so it does not test vision or fusion.","The test set contains one seed and is smoke-scale; confidence intervals and headline research claims are deferred."]}
    return result

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--dataset",required=True); ap.add_argument("--runs",required=True); ap.add_argument("--output",required=True)
    a=ap.parse_args(); root=Path(a.dataset); out=[]
    for ck in sorted(Path(a.runs).glob("*/checkpoint.pt")):
        out.append(score(root,ck,ck.parent.name.split("_")[0]))
    payload={"study":"Pigeon Observer Study 1","dataset_version":"pigeon-observer-v1","results":out,
             "status":"smoke_only_not_research_result",
             "limitations":["The held-out seed has one panic class, so AUROC and R² are undefined.","No rendered frames were available; vision and fusion were not evaluated.","Training used a short CPU budget and three scenarios, not the planned headline study."]}
    Path(a.output).write_text(json.dumps(payload,indent=2,allow_nan=False,default=lambda x: None)+"\n")
if __name__ == "__main__": main()
