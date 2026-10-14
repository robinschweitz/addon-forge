import json
import pytest
from addon_forge.scenario_plan import validate_plan, load_plan, evaluate


def plan(peers=1):
    return {"version":1,"addon":"SimpleClock","character":"Forgechar",
            "peers":peers,"checks":[{"type":"player_in_world","value":True},
                                    {"type":"target_player","value":True},
                                    {"type":"frame_visible","value":"ClockFrame"}]}


def test_validation_accepts_bounded_plan(tmp_path):
    candidate=plan()
    path=tmp_path/"scenario.json"
    path.write_text(json.dumps(candidate))
    assert load_plan(path)==candidate


def test_independent_snapshot_assertions():
    observed={"completed":True,"snapshot":{
        "player":{"exists":True},"target":{"isPlayer":True},
        "frames":{"ClockFrame":{"shown":True}},"party":{"count":0}}}
    answer=evaluate(plan(),observed)
    assert answer["status"]=="passed"
    observed["snapshot"]["frames"]["ClockFrame"]["shown"]=False
    answer=evaluate(plan(),observed)
    assert answer["status"]=="failed"
    assert answer["checks"][-1]["actual"] is False


def test_missing_telemetry_is_error_not_success():
    assert evaluate(plan(),{"completed":True})["status"]=="infrastructure_error"


@pytest.mark.parametrize("modify", [
    lambda x: x.update({"peers":5}),
    lambda x: x.update({"character":"Unknown 123"}),
    lambda x: x["checks"].append({"type":"execute_code","value":"rm -rf"}),
    lambda x: x["checks"].append({"type":"target_player","value":True}),
    lambda x: x.update({"unchecked_commands":[".server restart"]}),
    lambda x: x.update({"peers":0}),
])
def test_reject_unsafe_or_unjudgeable_plans(modify):
    candidate=plan()
    modify(candidate)
    with pytest.raises(ValueError):
        validate_plan(candidate)


def test_check_frame_not_reported_is_not_a_false_pass():
    observed={"completed":True,"snapshot":{
        "player":{"exists":True},"target":{"isPlayer":True},"frames":{}}}
    answer=evaluate(plan(),observed)
    assert answer["status"]=="failed"
    assert answer["checks"][-1]["actual"] is None


def test_sdk_only_plan_accepts_world_observation():
    candidate = {"version": 1, "addon": "SimpleClock", "character": "Test",
                 "peers": 0, "observer": "sdk",
                 "checks": [{"type": "player_in_world", "value": True}]}
    assert validate_plan(candidate) == candidate


def test_sdk_only_rejects_frame_checks_before_starting_client():
    candidate = {"version": 1, "addon": "SimpleClock", "character": "Test",
                 "peers": 0, "observer": "sdk",
                 "checks": [{"type": "frame_visible", "value": "ClockFrame"}]}
    with pytest.raises(ValueError, match="require the bridge"):
        validate_plan(candidate)


def test_sdk_only_rejects_peers():
    candidate = {"version": 1, "addon": "SimpleClock", "character": "Test",
                 "peers": 1, "observer": "sdk",
                 "checks": [{"type": "player_in_world", "value": True}]}
    with pytest.raises(ValueError, match="only player_in_world"):
        validate_plan(candidate)
