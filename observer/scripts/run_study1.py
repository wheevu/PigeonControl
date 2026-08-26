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

def collect(root: Path, checkpoint: Path, split: str):
    ds = ObserverSequenceDataset(root, split, mode="telemetry", sequence_length=8, horizon=6)
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
    return rows, sum(p.numel() for p in model.parameters())

def score(root: Path, checkpoint: Path, temporal: str):
    val_rows, _ = collect(root, checkpoint, "validation")
    test_rows, params = collect(root, checkpoint, "test")
    vy=np.array([r["panic"] for r in val_rows]); vp=np.array([r["panic_prob"] for r in val_rows])
    thresholds=np.linspace(0.05,0.95,19)
    def f1_at(t):
        pred=vp>=t; tp=np.sum(pred & (vy==1)); fp=np.sum(pred & (vy==0)); fn=np.sum((~pred) & (vy==1))
        precision=tp/max(1,tp+fp); recall=tp/max(1,tp+fn)
        return 2*precision*recall/max(1e-12,precision+recall)
    threshold=max(thresholds, key=f1_at)
    rows=test_rows; y=np.array([r["panic"] for r in rows]); p=np.array([r["panic_prob"] for r in rows]); yp=(p>=threshold).astype(int)
    from sklearn.metrics import average_precision_score
    pr_auc=float(average_precision_score(y,p)) if len(np.unique(y)) > 1 else None
    fear_metrics=regression_metrics([r["fear"] for r in rows],[r["fear_pred"] for r in rows])
    greed_metrics=regression_metrics([r["greed"] for r in rows],[r["greed_pred"] for r in rows])
    for metrics in (fear_metrics, greed_metrics):
        for key, value in list(metrics.items()):
            if not np.isfinite(value): metrics[key]=None
    result={"temporal":temporal,"checkpoint":str(checkpoint),"parameters":params,"validation_threshold":float(threshold),
            "n_test_windows":len(rows),"seeds":sorted(set(r["seed"] for r in rows)),
            "panic":{**classification_metrics(y,yp,p),**calibration_metrics(y,p),"pr_auc":pr_auc,
                      "class_counts":{"negative":int((y==0).sum()),"positive":int((y==1).sum())}},
            "fear":fear_metrics,"greed":greed_metrics,
            "negative_findings":["This study has no rendered frames, so it does not test vision or fusion.","The test set contains one seed and is smoke-scale; confidence intervals and headline research claims are deferred."]}
    return result

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--dataset",required=True); ap.add_argument("--runs",required=True); ap.add_argument("--output",required=True)
    a=ap.parse_args(); root=Path(a.dataset); out=[]
    for ck in sorted(Path(a.runs).glob("*/checkpoint.pt")):
        out.append(score(root,ck,ck.parent.name.split("_")[0]))
    payload={"study":"Pigeon Observer Study 3","dataset_version":"pigeon-observer-v1","results":out,
             "status":"smoke_only_not_research_result",
             "limitations":["The held-out split contains two seeds, so uncertainty remains wide.","No rendered frames were available; vision and fusion were not evaluated.","GRU and Transformer parameter counts are not matched."]}
    Path(a.output).write_text(json.dumps(payload,indent=2,allow_nan=False,default=lambda x: None)+"\n")
if __name__ == "__main__": main()
