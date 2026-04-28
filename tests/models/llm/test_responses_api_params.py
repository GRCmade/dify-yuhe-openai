from pathlib import Path
from types import SimpleNamespace
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from models.llm.llm import OpenAILargeLanguageModel
from dify_plugin.entities.model.message import UserPromptMessage


def test_build_responses_api_params_strips_gateway_incompatible_fields() -> None:
    llm = OpenAILargeLanguageModel.__new__(OpenAILargeLanguageModel)

    params = llm._build_responses_api_params(
        model_parameters={
            "metadata": {"trace_id": "abc"},
            "presence_penalty": 0.1,
            "frequency_penalty": 0.2,
            "max_tokens": 128,
            "reasoning_effort": "medium",
        },
        user="8fd0b216-5d4a-4082-a25b-f76411d8fb8d",
    )

    assert "metadata" not in params
    assert "presence_penalty" not in params
    assert "frequency_penalty" not in params
    assert "user" not in params
    assert params["max_output_tokens"] == 128
    assert params["reasoning"] == {"effort": "medium"}


def test_normalize_json_schema_config_unwraps_dify_wrapper() -> None:
    llm = OpenAILargeLanguageModel.__new__(OpenAILargeLanguageModel)

    schema = llm._normalize_json_schema_config(
        {
            "type": "json_schema",
            "json_schema": {
                "name": "coordinate_schema",
                "strict": True,
                "schema": {
                    "type": "object",
                    "properties": {
                        "x": {"type": "integer"},
                        "y": {"type": "integer"},
                    },
                    "required": ["x", "y"],
                    "additionalProperties": False,
                },
            },
        }
    )

    assert schema["name"] == "coordinate_schema"
    assert schema["strict"] is True
    assert schema["schema"]["type"] == "object"


def test_build_responses_api_params_accepts_inner_json_schema_config() -> None:
    llm = OpenAILargeLanguageModel.__new__(OpenAILargeLanguageModel)

    params = llm._build_responses_api_params(
        model_parameters={
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "coordinate_schema",
                    "strict": True,
                    "schema": {
                        "type": "object",
                        "properties": {
                            "x": {"type": "integer"},
                            "y": {"type": "integer"},
                        },
                        "required": ["x", "y"],
                        "additionalProperties": False,
                    },
                },
            }
        }
    )

    assert params["text"]["format"]["type"] == "json_schema"
    assert params["text"]["format"]["name"] == "coordinate_schema"
    assert params["text"]["format"]["strict"] is True
    assert params["text"]["format"]["schema"]["type"] == "object"


def test_uses_json_schema_response_format_detects_supported_shapes() -> None:
    llm = OpenAILargeLanguageModel.__new__(OpenAILargeLanguageModel)

    assert llm._uses_json_schema_response_format({"response_format": "json_schema"}) is True
    assert llm._uses_json_schema_response_format({"response_format": {"type": "json_schema"}}) is True
    assert llm._uses_json_schema_response_format({"text": {"format": {"type": "json_schema"}}}) is True
    assert llm._uses_json_schema_response_format({"response_format": "text"}) is False


def test_responses_api_stream_buffers_json_schema_output_until_completed() -> None:
    llm = OpenAILargeLanguageModel.__new__(OpenAILargeLanguageModel)
    llm._calc_response_usage = lambda *args, **kwargs: None  # type: ignore[method-assign]

    stream_events = [
        SimpleNamespace(type="response.output_text.delta", delta='{"x"', text=None),
        SimpleNamespace(type="response.output_text.delta", delta=':1,"y":2}', text=None),
        SimpleNamespace(
            type="response.completed",
            response=SimpleNamespace(
                model="gpt-5.4",
                usage=SimpleNamespace(input_tokens=10, output_tokens=5),
                output_text='{"x":1,"y":2}',
            ),
        ),
    ]

    class FakeResponsesClient:
        def create(self, **kwargs):
            return iter(stream_events)

    class FakeClient:
        responses = FakeResponsesClient()

    chunks = list(
        llm._chat_generate_responses_api_stream(
            model="gpt-5.4",
            credentials={},
            prompt_messages=[UserPromptMessage(content="hi")],
            model_parameters={
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {"name": "coordinate_schema", "schema": {"type": "object"}},
                }
            },
            tools=None,
            client=FakeClient(),
        )
    )

    assert [chunk.delta.message.content for chunk in chunks] == ['{"x":1,"y":2}', ""]
    assert chunks[-1].delta.finish_reason == "stop"
