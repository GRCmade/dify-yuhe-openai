from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from models.llm.llm import OpenAILargeLanguageModel


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
