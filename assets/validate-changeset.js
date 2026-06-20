'use strict';

/**
 * Reusable change-set validator for workbench-ynab write-back (M4).
 *
 * Loads assets/changeset-schema.json and validates a change-set object against
 * it, returning a structured { valid, errors } result. Other plugin code (the
 * apply executor, the /ynab-apply command, the dry-run path) imports
 * validateChangeset to reject malformed change-sets before doing anything.
 *
 * Validator: Ajv (https://ajv.js.org) with the JSON Schema 2020-12 dialect and
 * ajv-formats for date / date-time. See changeset-contract.md for why Ajv and
 * how to install it (assets/package.json).
 *
 * Usage as a library:
 *   const { validateChangeset } = require('./assets/validate-changeset');
 *   const { valid, errors } = validateChangeset(myChangeSet);
 *
 * Usage as a CLI (validates one or more fixtures, exits non-zero on failure):
 *   node assets/validate-changeset.js assets/fixtures/categorize.example.json
 *   npm --prefix assets run validate:fixtures
 */

const fs = require('fs');
const path = require('path');
const Ajv2020 = require('ajv/dist/2020');
const addFormats = require('ajv-formats');

const SCHEMA_PATH = path.join(__dirname, 'changeset-schema.json');

/** Load the change-set JSON Schema from disk. */
function loadSchema() {
  return JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));
}

let _validate;

/** Compile (once) and return the Ajv validate function for the schema. */
function getValidator() {
  if (!_validate) {
    const ajv = new Ajv2020({ allErrors: true, strict: false });
    addFormats(ajv);
    _validate = ajv.compile(loadSchema());
  }
  return _validate;
}

/**
 * Validate a change-set object against the schema.
 * @param {unknown} changeset - the parsed change-set object to validate.
 * @returns {{ valid: boolean, errors: Array<{path: string, keyword: string, message: string, params: object}> }}
 */
function validateChangeset(changeset) {
  const validate = getValidator();
  const valid = validate(changeset);
  return {
    valid: Boolean(valid),
    errors: valid
      ? []
      : (validate.errors || []).map((e) => ({
          path: e.instancePath || '/',
          keyword: e.keyword,
          message: e.message || '',
          params: e.params || {},
        })),
  };
}

module.exports = { validateChangeset, loadSchema, SCHEMA_PATH };

// CLI entry point.
if (require.main === module) {
  const files = process.argv.slice(2);
  if (files.length === 0) {
    console.error('usage: node validate-changeset.js <changeset.json> [more.json ...]');
    process.exit(2);
  }
  let failed = 0;
  for (const file of files) {
    let data;
    try {
      data = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (err) {
      failed += 1;
      console.error(`FAIL  ${file}\n        could not read/parse: ${err.message}`);
      continue;
    }
    const result = validateChangeset(data);
    if (result.valid) {
      console.log(`PASS  ${file}`);
    } else {
      failed += 1;
      console.error(`FAIL  ${file}`);
      for (const err of result.errors) {
        console.error(`        ${err.path} ${err.message}`);
      }
    }
  }
  process.exit(failed ? 1 : 0);
}
