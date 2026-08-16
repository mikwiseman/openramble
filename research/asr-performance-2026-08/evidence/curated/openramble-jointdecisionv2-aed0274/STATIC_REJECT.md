# JointDecisionv2 static verdict

Decision: **REJECT without inference**.

At official model revision
`aed02740059203c4a87495924f685de3722ae9ce`, `JointDecisionv2.mlmodelc`
has the same two inputs, the same five outputs, the same 12,642,764-byte
weight (`4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e`),
and the same MIL body as shipping `JointDecisionv3.mlmodelc`. The only MIL
diff is the `coremlc` build-info version header. It still computes the full
softmax and `topk(k=64)` and therefore has no structural performance
hypothesis to test.

- v2 MIL SHA-256: `184981bd09f11f9ce3e5ae26ee176a50045fa29f2d88e563fdb774a938e2afc1`
- v3 MIL SHA-256: `be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d`
- v2 metadata SHA-256: `dafc5431893bf3b2e6772702317a429962a1ba5e379074c9e9a741d19d663523`

No model was loaded and no Core ML inference was run for this candidate.
