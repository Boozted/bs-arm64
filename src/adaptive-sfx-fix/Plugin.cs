using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using HarmonyLib;
using IPA;
using IPA.Logging;

namespace BsArm64.AdaptiveSfxFix
{
    [Plugin(RuntimeOptions.SingleStartInit)]
    public sealed class Plugin
    {
        private const string HarmonyId = "com.davarga.bs-arm64.adaptive-sfx-fix";
        private static readonly MethodInfo MathPow = AccessTools.Method(
            typeof(Math), "Pow", new[] { typeof(double), typeof(double) });
        private static readonly MethodInfo FastSquare = AccessTools.Method(
            typeof(Plugin), "SquareIfExponentIsTwo");

        private static Logger logger;
        private static int replacementCount;

        [Init]
        public Plugin(Logger pluginLogger)
        {
            logger = pluginLogger;
        }

        [OnStart]
        public void OnStart()
        {
            try
            {
                MethodInfo[] targets = FindRmsJobMethods().ToArray();
                if (targets.Length == 0)
                {
                    logger.Warn("CalculateRmsBlockJob.Execute was not found; Adaptive SFX was not patched.");
                    return;
                }

                MethodInfo transpiler = AccessTools.Method(typeof(Plugin), "ReplacePowCalls");
                var harmony = new Harmony(HarmonyId);
                foreach (MethodInfo target in targets)
                    harmony.Patch(target, transpiler: new HarmonyMethod(transpiler));

                if (replacementCount == 0)
                {
                    logger.Warn("The RMS job had no Math.Pow calls; Adaptive SFX was not changed.");
                    return;
                }

                logger.Info(string.Format(
                    "Adaptive SFX fix active: replaced {0} RMS Math.Pow call(s).", replacementCount));
            }
            catch (Exception exception)
            {
                logger.Error("Adaptive SFX patch failed: " + exception);
            }
        }

        private static IEnumerable<MethodInfo> FindRmsJobMethods()
        {
            return AppDomain.CurrentDomain.GetAssemblies()
                .SelectMany(GetLoadableTypes)
                .Where(type => type.Name == "CalculateRmsBlockJob" && type.Namespace == "LufsMetering")
                .SelectMany(type => type.GetMethods(
                    BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic))
                .Where(method => method.Name == "Execute");
        }

        private static IEnumerable<Type> GetLoadableTypes(Assembly assembly)
        {
            try
            {
                return assembly.GetTypes();
            }
            catch (ReflectionTypeLoadException exception)
            {
                return exception.Types.Where(type => type != null);
            }
        }

        private static IEnumerable<CodeInstruction> ReplacePowCalls(
            IEnumerable<CodeInstruction> instructions)
        {
            foreach (CodeInstruction instruction in instructions)
            {
                if (instruction.Calls(MathPow))
                {
                    instruction.operand = FastSquare;
                    replacementCount++;
                }

                yield return instruction;
            }
        }

        // The RMS job always raises samples to 2. Preserve Math.Pow for any unexpected exponent.
        public static double SquareIfExponentIsTwo(double value, double exponent)
        {
            return exponent == 2.0 ? value * value : Math.Pow(value, exponent);
        }
    }
}
