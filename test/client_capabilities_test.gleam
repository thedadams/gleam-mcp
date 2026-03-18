import gleam/option.{None, Some}
import gleam_mcp/actions
import gleam_mcp/client/capabilities
import gleam_mcp/jsonrpc.{VObject}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn none_config_produces_empty_capabilities_test() {
  capabilities.none()
  |> capabilities.to_initialize_capabilities
  |> should.equal(actions.ClientCapabilities(
    experimental: None,
    roots: None,
    sampling: None,
    elicitation: None,
    tasks: None,
  ))
}

pub fn roots_capability_tracks_list_changed_support_test() {
  let config =
    capabilities.Config(
      list_roots: Some(fn() { Ok([]) }),
      notify_roots_list_changed: Some(fn() { Ok(Nil) }),
      create_message: None,
      sampling_tools: None,
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  capabilities.to_initialize_capabilities(config)
  |> should.equal(actions.ClientCapabilities(
    experimental: None,
    roots: Some(actions.ClientRootsCapabilities(list_changed: Some(True))),
    sampling: None,
    elicitation: None,
    tasks: None,
  ))
}

pub fn roots_capability_is_disabled_without_list_roots_test() {
  let config =
    capabilities.Config(
      list_roots: None,
      notify_roots_list_changed: Some(fn() { Ok(Nil) }),
      create_message: None,
      sampling_tools: None,
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  let actions.ClientCapabilities(roots: roots, ..) =
    capabilities.to_initialize_capabilities(config)
  roots |> should.be_none
}

pub fn sampling_capability_reports_available_handlers_test() {
  let config =
    capabilities.Config(
      list_roots: None,
      notify_roots_list_changed: None,
      create_message: None,
      sampling_tools: Some(fn(_) { Ok(Nil) }),
      sampling_context: None,
      elicit_form: None,
      elicit_url: None,
    )

  let actions.ClientCapabilities(sampling: sampling, ..) =
    capabilities.to_initialize_capabilities(config)

  sampling
  |> should.equal(
    Some(actions.ClientSamplingCapabilities(
      context: None,
      tools: Some(VObject([])),
    )),
  )
}

pub fn elicitation_capability_reports_available_handlers_test() {
  let config =
    capabilities.Config(
      list_roots: None,
      notify_roots_list_changed: None,
      create_message: None,
      sampling_tools: None,
      sampling_context: None,
      elicit_form: Some(fn(_) { Ok(VObject([])) }),
      elicit_url: Some(fn(_) { Ok(VObject([])) }),
    )

  let actions.ClientCapabilities(elicitation: elicitation, ..) =
    capabilities.to_initialize_capabilities(config)

  elicitation
  |> should.equal(
    Some(actions.ClientElicitationCapabilities(
      form: Some(VObject([])),
      url: Some(VObject([])),
    )),
  )
}
