/* Cross-language bridge for `Tests/site/test_publish_net_sales.py`.
 *
 * Reads a public aggregate on stdin, runs the REAL browser renderer over it, and prints
 * the view model as JSON. Exists so the Python suite can assert that the publisher's
 * actual output satisfies the actual renderer — two independent implementations of the
 * same money rules drift unless something runs both.
 */
import { fundingView } from "../../docs/assets/funding.js";

const today = process.argv[2];
let raw = "";
for await (const chunk of process.stdin) raw += chunk;
process.stdout.write(JSON.stringify(fundingView(JSON.parse(raw), today)));
