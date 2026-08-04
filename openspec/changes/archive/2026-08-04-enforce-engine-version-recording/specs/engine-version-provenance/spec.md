## ADDED Requirements

### Requirement: Every OCR execution point declares its version

Every engine SHALL declare the version of the tool that produced its output, together with how that version was obtained. The declaration SHALL be a protocol requirement without a default implementation, so that an engine which does not declare a version fails to compile rather than emitting results with an absent version.

#### Scenario: An engine completes recognition

- **WHEN** any engine finishes recognizing a document
- **THEN** the condition information carried by the result SHALL include version data
- **AND** that version data SHALL name how it was obtained

#### Scenario: A new engine omits the version declaration

- **WHEN** a new type conforms to the engine protocol without declaring a version
- **THEN** compilation SHALL fail
- **AND** no default value SHALL be supplied on its behalf

### Requirement: Version data records components and how they were obtained

Version data SHALL consist of a mapping from component name to component version, and a resolution value naming how the version was obtained. The resolution SHALL be exactly one of: declared by the engine, probed at run time, reported by an adapter, or unavailable.

Version data SHALL NOT carry a separate "primary version" field. Which component is primary is a consumer-side judgement and SHALL NOT be fixed by the producer.

#### Scenario: A component version is obtained by probing

- **WHEN** an engine obtains its version by executing a command at run time
- **THEN** the resolution SHALL be recorded as probed

#### Scenario: A version comes from an adapter

- **WHEN** an engine receives its version from an adapter process
- **THEN** the resolution SHALL be recorded as adapter-reported
- **AND** the value SHALL NOT be presented as verified

##### Example: Resolution values across engine families

| Engine family | Components | Resolution |
| --- | --- | --- |
| Operating-system framework | `["macOS": "26.0"]` | declared |
| External CLI | `["tesseract": "5.3.4"]` | probed |
| Adapter-backed tool | `["surya-ocr": "0.22.1"]` | adapter-reported |
| Cloud service | empty | unavailable |

### Requirement: Unavailable versions are recorded, not omitted

When a version cannot be obtained, the engine SHALL record an empty component mapping with the resolution set to unavailable. The engine SHALL NOT substitute a plausible version number, and SHALL NOT omit version data entirely.

Failure to obtain a version SHALL NOT fail recognition.

#### Scenario: Version probing fails

- **WHEN** an engine attempts to probe its version and the command is absent, times out, or returns nothing usable
- **THEN** recognition SHALL still complete
- **AND** the result SHALL carry an empty component mapping with resolution unavailable

#### Scenario: A cloud service does not expose a version

- **WHEN** a cloud provider gives no version for the model that served the request
- **THEN** the resolution SHALL be unavailable
- **AND** no version number SHALL be inferred from the provider name, the request date, or any previously observed value

### Requirement: Existing archived results remain decodable

The version field on stored condition information SHALL remain optional so that results archived before this change continue to decode. Enforcement SHALL be applied on the write path, through the engine protocol and the construction path, and SHALL NOT be applied by making the stored field required.

Results archived before this change SHALL be treated as having an unknown version, and their version SHALL NOT be inferred after the fact.

#### Scenario: Decoding a result archived before this change

- **WHEN** a stored result whose version field is absent is decoded
- **THEN** decoding SHALL succeed
- **AND** the version SHALL be reported as unknown rather than reconstructed

### Requirement: All construction paths carry version data

Every path that constructs condition information SHALL carry version data, including paths that do not belong to an engine type.

#### Scenario: Condition information is constructed outside an engine

- **WHEN** condition information is constructed by the run-logging path rather than by an engine
- **THEN** the resulting record SHALL carry version data on the same terms as engine-produced records
