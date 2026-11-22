#!/usr/bin/env python3
"""Собирает нативные команды Focus. Результат подписывается через shortcuts sign."""
import argparse
import json
from pathlib import Path
import plistlib
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--dnd-name", default="Do Not Disturb",
                    help="Нативное имя выбранной цели DND в языке macOS")
args = parser.parse_args()
if not args.dnd_name.strip():
    parser.error("Имя целевого DND не должно быть пустым")
args.output.mkdir(parents=True, exist_ok=True)


def action(identifier, **parameters):
    return {"WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": parameters}


def text_token(value):
    return {"WFSerializationType": "WFTextTokenString", "Value": {
        "string": "\ufffc", "attachmentsByRange": {"{0, 1}": value}}}


date_id = str(uuid.uuid4()).upper()
# Срок службы180с начинается до команды. Системный срок180с начинается внутри
# команды и гарантирует конечное выключение даже после аварии процесса OwnShot.
# Native Adjust Date не зависит от неоднозначного разбора ISO8601 в Get Dates.
adjust_date = action("is.workflow.actions.adjustdate", UUID=date_id,
    WFDate=text_token({"Type": "CurrentDate"}), WFAdjustOperation="Add",
    WFDuration={"WFSerializationType": "WFQuantityFieldValue",
                "Value": {"Magnitude": 180, "Unit": "sec"}},
    WFAdjustOffsetPicker={"WFSerializationType": "WFTimeOffsetValue",
                         "Value": {"Operation": "Add", "Unit": "Second", "Value": 180}})
receipt = json.dumps({"identifier": "com.apple.donotdisturb.mode.default",
                      "name": args.dnd_name}, ensure_ascii=False, separators=(",", ":"))
commands = {
    "OwnShot Focus Status": [action("is.workflow.actions.dnd.getfocus")],
    "OwnShot Focus On": [adjust_date, action("is.workflow.actions.dnd.set",
        Operation="Turn", Enabled=True, AssertionType="Time",
        Time=text_token({"Type": "ActionOutput", "OutputUUID": date_id,
                         "OutputName": "Adjusted Date"})),
        action("is.workflow.actions.gettext", WFTextActionText=receipt)],
    "OwnShot Focus Off": [action("is.workflow.actions.dnd.set", Operation="Turn", Enabled=False)],
}
for name, actions in commands.items():
    workflow = {"WFWorkflowName": name, "WFWorkflowActions": actions,
        "WFWorkflowClientRelease": "6.0", "WFWorkflowClientVersion": "3036.0.4.1.3",
        "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowTypes": [], "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"],
        "WFInputSurfaces": [], "WFWorkflowImportQuestions": [], "WFWorkflowHasShortcutInputVariables": True}
    (args.output / (name + ".unsigned.shortcut")).write_bytes(plistlib.dumps(workflow, fmt=plistlib.FMT_BINARY))
